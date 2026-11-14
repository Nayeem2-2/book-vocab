import 'dart:async';

import 'package:flutter/material.dart';
import 'package:indexed_sliver_list/indexed_sliver_list.dart';

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
  IndexedScrollController _scrollController = IndexedScrollController();
  final Set<String> _selectedBookIds = <String>{};
  String _query = '';
  _BooksListData? _cachedListData;
  Timer? _searchDebounce;

  bool get _selectionMode => _selectedBookIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreStructureChanged);
  }

  @override
  void didUpdateWidget(covariant BooksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreStructureChanged);
      widget.store.addListener(_onStoreStructureChanged);
      _cachedListData = null;
      _replaceListController();
    }
  }

  void _onStoreStructureChanged() {
    // Structural changes can alter names, groups and measured row indexes.
    _cachedListData = null;
    _replaceListController();
  }

  void _replaceListController() {
    final oldController = _scrollController;
    _scrollController = IndexedScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController.dispose();
    });
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreStructureChanged);
    _searchDebounce?.cancel();
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

  void _scheduleSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 140), () {
      if (!mounted || value == _query) return;
      _cachedListData = null;
      _replaceListController();
      setState(() => _query = value);
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _cachedListData = null;
    _replaceListController();
    setState(() => _query = '');
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: TextField(
        controller: _searchController,
        onChanged: _scheduleSearch,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search books...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: _clearSearch,
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
            subtitle: ValueListenableBuilder<int>(
              valueListenable: widget.store.wordStateRevision,
              builder: (context, _, __) => FutureBuilder<void>(
                future: widget.store.ensureBookWordCache(book),
                builder: (context, snapshot) {
                  final structureLabel = book.isImageBook
                      ? '${book.pages.length} Pages'
                      : '${book.parts.length} Parts';
                  final statsReady = widget.store.hasBookWordCache(book);
                  final subtitle = statsReady
                      ? '$structureLabel  •  ${widget.store.totalUniqueWords(book)} unique words\n${widget.store.knownCount(book)} known'
                      : '$structureLabel  •  Preparing vocabulary statistics…';
                  return Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
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
                        book: book,
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

  Map<String, List<BookData>> _groupBooksByInitial(List<BookData> books) {
    final groups = <String, List<BookData>>{};
    for (final book in books) {
      final trimmed = book.name.trim();
      final initial = trimmed.isEmpty ? '#' : trimmed[0].toUpperCase();
      final letter = isEnglishAlphabetLetter(initial) ? initial : '#';
      groups.putIfAbsent(letter, () => <BookData>[]).add(book);
    }
    return groups;
  }

  _BooksListData _listData() {
    final cached = _cachedListData;
    if (cached != null && cached.query == _query) return cached;

    final filteredBooks = rankAndSortByName<BookData>(
      widget.store.books,
      (book) => book.name,
      _query,
    );
    final groupedBooks = _groupBooksByInitial(filteredBooks);
    final rows = <Object>[];
    final sectionIndexes = <String, int>{};
    for (final group in groupedBooks.entries) {
      sectionIndexes[group.key] = rows.length;
      rows.add(group.key);
      rows.addAll(group.value);
    }
    final indexLetters = groupedBooks.keys
        .where((letter) => isEnglishAlphabetLetter(letter))
        .toList(growable: false);

    final data = _BooksListData(
      query: _query,
      filteredBooks: filteredBooks,
      rows: rows,
      sectionIndexes: sectionIndexes,
      indexLetters: indexLetters,
    );
    _cachedListData = data;
    return data;
  }

  Widget _letterHeader(String letter) {
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 7, 12, 3),
        child: Row(
          children: [
            Text(
              letter,
              style: const TextStyle(
                color: Color(0xFF356859),
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Divider(color: const Color(0xFF356859).withOpacity(0.18)),
            ),
          ],
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
        final listData = _listData();
        final filteredBooks = listData.filteredBooks;
        final rows = listData.rows;
        final sectionIndexes = listData.sectionIndexes;
        final indexLetters = listData.indexLetters;

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
                            child: IndexedListView(
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(12, 0, 27, 100),
                              itemCount: rows.length,
                              estimatedItemExtent: 108,
                              addAutomaticKeepAlives: false,
                              itemBuilder: (context, index) {
                                final row = rows[index];
                                return row is String
                                    ? _letterHeader(row)
                                    : _bookTile(row as BookData);
                              },
                            ),
                          ),
                          if (indexLetters.isNotEmpty)
                            Positioned(
                              right: 1,
                              top: 4,
                              bottom: 104,
                              child: AlphabetFastScroller(
                                controller: _scrollController,
                                names: indexLetters,
                                itemExtent: 0,
                                onLetterSelected: (letter) {
                                  final target = sectionIndexes[letter];
                                  if (target == null || !_scrollController.hasClients) {
                                    return;
                                  }
                                  unawaited(_scrollController.jumpToIndex(
                                    target,
                                    alignment: 0,
                                  ));
                                },
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


class _BooksListData {
  const _BooksListData({
    required this.query,
    required this.filteredBooks,
    required this.rows,
    required this.sectionIndexes,
    required this.indexLetters,
  });

  final String query;
  final List<BookData> filteredBooks;
  final List<Object> rows;
  final Map<String, int> sectionIndexes;
  final List<String> indexLetters;
}
