import 'package:flutter/material.dart';

import '../models/book_models.dart';
import '../services/book_store.dart';
import '../widgets/alphabet_fast_scroller.dart';
import '../widgets/name_input_dialog.dart';
import '../widgets/play_widgets.dart';
import 'parts_page.dart';
import 'pages_page.dart';

class BooksPage extends StatefulWidget {
  const BooksPage({super.key, required this.store});
  final BookStore store;

  @override
  State<BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends State<BooksPage> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Set<String> _selectedBookIds = <String>{};
  String _query = '';

  bool get _selectionMode => _selectedBookIds.isNotEmpty;

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addBook() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.data_object),
              title: const Text('Import JSON book'),
              subtitle: const Text('Keep the existing Parts → Chapters structure'),
              onTap: () => Navigator.pop(context, 'json'),
            ),
            ListTile(
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('Create image book'),
              subtitle: const Text('Add scanned or selected page images'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;

    if (choice == 'json') {
      try {
        await widget.store.importBook();
      } catch (error) {
        _message('Could not import book: $error');
      }
      return;
    }

    final name = await showDialog<String>(
      context: context,
      builder: (_) => const NameInputDialog(
        title: 'Create image book',
        label: 'Book name',
        hintText: 'e.g. English Vocabulary',
        submitLabel: 'Create',
      ),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;

    try {
      await widget.store.createImageBook(name);
    } catch (error) {
      _message('Could not create image book: $error');
    }
  }

  Future<void> _exportKnown() async {
    try {
      final path = await widget.store.exportKnownWords();
      if (path != null) _message('Known words exported');
    } catch (error) {
      _message('Export failed: $error');
    }
  }

  Future<void> _importKnown() async {
    try {
      final added = await widget.store.importKnownWords();
      if (added != null) {
        _message('Imported and merged • $added new known words');
      }
    } catch (error) {
      _message('Import failed: $error');
    }
  }

  void _toggleSelection(BookData book) {
    setState(() {
      if (!_selectedBookIds.add(book.id)) {
        _selectedBookIds.remove(book.id);
      }
    });
  }

  void _clearSelection() {
    if (!mounted || _selectedBookIds.isEmpty) return;
    setState(_selectedBookIds.clear);
  }

  Future<void> _renameBook(BookData book) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => NameInputDialog(
        title: 'Rename book',
        label: 'Book name',
        initialValue: book.name,
        submitLabel: 'Save',
      ),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;

    try {
      await widget.store.renameBook(book, name);
      _message('Book renamed');
    } catch (error) {
      _message('Could not rename book: $error');
    }
  }

  Future<void> _confirmDeleteBooks(List<BookData> books) async {
    if (books.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(books.length == 1 ? 'Delete book?' : 'Delete ${books.length} books?'),
        content: Text(
          books.length == 1
              ? 'Delete “${books.first.name}” and all of its saved data?'
              : 'Delete these ${books.length} books and all associated saved data?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || yes != true) return;

    try {
      await widget.store.removeBooks(books);
      if (!mounted) return;
      _clearSelection();
      _message(books.length == 1 ? 'Book deleted' : '${books.length} books deleted');
    } catch (error) {
      _message('Could not delete book(s): $error');
    }
  }

  void _openBook(BookData book) {
    if (_selectionMode) {
      _toggleSelection(book);
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        settings: RouteSettings(name: book.isImageBook ? 'pages:${book.id}' : 'parts:${book.id}'),
        builder: (_) => book.isImageBook
            ? PagesPage(store: widget.store, book: book)
            : PartsPage(store: widget.store, book: book),
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: TextField(
        controller: _searchController,
        onChanged: (value) {
          if (_scrollController.hasClients) _scrollController.jumpTo(0);
          setState(() => _query = value);
        },
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search books...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    if (_scrollController.hasClients) _scrollController.jumpTo(0);
                    setState(() => _query = '');
                  },
                  icon: const Icon(Icons.close),
                ),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: const BorderSide(color: Color(0xFFE8ECE7)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: const BorderSide(color: Color(0xFFE8ECE7)),
          ),
        ),
      ),
    );
  }

  Widget _bookTile(BookData book) {
    final selected = _selectedBookIds.contains(book.id);
    return SizedBox(
      height: 112,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 5),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openBook(book),
          onLongPress: () => _toggleSelection(book),
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            leading: _selectionMode
                ? Icon(
                    selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: selected ? Theme.of(context).colorScheme.primary : Colors.black38,
                    size: 28,
                  )
                : Container(
                    width: 48,
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F1EC),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.menu_book_rounded,
                      color: Color(0xFF356859),
                      size: 28,
                    ),
                  ),
            title: Text(
              book.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                '${book.isImageBook ? '${book.pages.length} Pages' : '${book.parts.length} Parts'}  •  ${widget.store.totalUniqueWords(book)} unique words\n${widget.store.knownCount(book)} known',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            isThreeLine: true,
            trailing: _selectionMode
                ? const SizedBox(width: 4)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PlayButton(
                        store: widget.store,
                        title: book.name,
                        chapters: book.allChapters,
                        size: 32,
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Book options',
                        onSelected: (value) {
                          if (value == 'rename') _renameBook(book);
                          if (value == 'delete') _confirmDeleteBooks([book]);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'rename',
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.edit_outlined),
                              title: Text('Rename'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.delete_outline),
                              title: Text('Delete'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState({required bool noSearchMatches}) {
    if (noSearchMatches) {
      return const Center(child: Text('No books match your search.'));
    }
    return _EmptyState(onAdd: _addBook);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final filteredBooks = rankAndSortByName<BookData>(
          widget.store.books,
          (book) => book.name,
          _query,
        );

        return Scaffold(
          appBar: AppBar(
            leading: _selectionMode
                ? IconButton(
                    tooltip: 'Cancel selection',
                    onPressed: _clearSelection,
                    icon: const Icon(Icons.close),
                  )
                : null,
            title: Text(
              _selectionMode ? '${_selectedBookIds.length} selected' : 'My Books',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            actions: _selectionMode
                ? [
                    IconButton(
                      tooltip: 'Delete selected books',
                      onPressed: () => _confirmDeleteBooks(
                        widget.store.books
                            .where((book) => _selectedBookIds.contains(book.id))
                            .toList(),
                      ),
                      icon: const Icon(Icons.delete_outline),
                    ),
                    const SizedBox(width: 6),
                  ]
                : [
                    IconButton(
                      tooltip: 'Add a book',
                      onPressed: _addBook,
                      icon: const Icon(Icons.add_circle_outline, size: 28),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Known words',
                      icon: const Icon(Icons.more_vert),
                      onSelected: (value) {
                        if (value == 'export') _exportKnown();
                        if (value == 'import') _importKnown();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'export',
                          child: ListTile(
                            leading: Icon(Icons.file_upload_outlined),
                            title: Text('Export known words'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'import',
                          child: ListTile(
                            leading: Icon(Icons.file_download_outlined),
                            title: Text('Import known words'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 4),
                  ],
          ),
          floatingActionButton: _selectionMode || widget.store.books.isEmpty
              ? null
              : FloatingActionButton.extended(
                  onPressed: _addBook,
                  icon: const Icon(Icons.add),
                  label: const Text('Add book'),
                ),
          body: Column(
            children: [
              _searchField(),
              Expanded(
                child: filteredBooks.isEmpty
                    ? _emptyState(
                        noSearchMatches: widget.store.books.isNotEmpty && _query.trim().isNotEmpty,
                      )
                    : Stack(
                        children: [
                          Positioned.fill(
                            child: ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(12, 0, 27, 100),
                              itemExtent: 112,
                              itemCount: filteredBooks.length,
                              itemBuilder: (context, index) => _bookTile(filteredBooks[index]),
                            ),
                          ),
                          Positioned(
                            right: 1,
                            top: 4,
                            bottom: 104,
                            child: AlphabetFastScroller(
                              controller: _scrollController,
                              names: filteredBooks.map((book) => book.name).toList(),
                              itemExtent: 112,
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.library_books_outlined, size: 76, color: Color(0xFF8AA99A)),
              const SizedBox(height: 18),
              const Text('Your library is empty', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                'Add a JSON vocabulary book or create an image book from scanned pages.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, height: 1.4),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.upload_file), label: const Text('Add a book')),
            ],
          ),
        ),
      );
}
