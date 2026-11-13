import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/book_models.dart';
import '../services/book_store.dart';
import '../widgets/alphabet_fast_scroller.dart';
import '../widgets/play_widgets.dart';
import 'chapter_page.dart';

class PagesPage extends StatefulWidget {
  const PagesPage({super.key, required this.store, required this.book});
  final BookStore store;
  final BookData book;

  @override
  State<PagesPage> createState() => _PagesPageState();
}

class _PagesPageState extends State<PagesPage> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Set<String> _selectedPageIds = <String>{};
  String _query = '';
  bool busy = false;

  bool get _selectionMode => _selectedPageIds.isNotEmpty;

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _downloadDictionary() async {
    setState(() => busy = true);
    try {
      await widget.store.dictionary.load();
      _message('English–Bangla dictionary downloaded and cached for offline use.');
    } catch (error) {
      _message('Dictionary download failed. Check internet and retry: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addPage() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.document_scanner_outlined),
                title: const Text('Camera'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('Pick image file'),
                onTap: () => Navigator.pop(context, 'file'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;

    setState(() => busy = true);
    try {
      if (choice == 'camera') {
        final result = await CunningDocumentScanner.scanDocuments();
        final paths = result?.images ?? const <String>[];
        for (final path in paths) {
          await widget.store.addScannedPage(widget.book, await File(path).readAsBytes());
        }
        if (paths.isNotEmpty) _message('${paths.length} page(s) scanned and processed.');
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'tif', 'tiff'],
          allowMultiple: true,
          withData: true,
        );
        if (result != null) {
          var added = 0;
          for (final picked in result.files) {
            final bytes = picked.bytes ??
                (picked.path == null ? null : await File(picked.path!).readAsBytes());
            if (bytes != null) {
              await widget.store.addScannedPage(widget.book, bytes);
              added++;
            }
          }
          if (added > 0) _message('$added image(s) added.');
        }
      }
    } catch (error) {
      _message('Could not add page: $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _togglePageSelection(ChapterData page) {
    setState(() {
      if (!_selectedPageIds.add(page.stableId)) {
        _selectedPageIds.remove(page.stableId);
      }
    });
  }

  void _clearSelection() {
    if (!mounted || _selectedPageIds.isEmpty) return;
    setState(_selectedPageIds.clear);
  }

  Future<void> _rename(ChapterData page) async {
    final controller = TextEditingController(text: page.title);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename page'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Page name'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;

    try {
      await widget.store.renamePage(widget.book, page, name);
      _message('Page renamed');
    } catch (error) {
      _message('Could not rename page: $error');
    }
  }

  Future<void> _confirmDeletePages(List<ChapterData> pages) async {
    if (pages.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(pages.length == 1 ? 'Delete page?' : 'Delete ${pages.length} pages?'),
        content: Text(
          pages.length == 1
              ? 'Delete “${pages.first.title}” and its saved image?'
              : 'Delete these ${pages.length} pages and their saved images?',
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
      await widget.store.deletePages(widget.book, pages);
      if (!mounted) return;
      _clearSelection();
      _message(pages.length == 1 ? 'Page deleted' : '${pages.length} pages deleted');
    } catch (error) {
      _message('Could not delete page(s): $error');
    }
  }

  void _openPage(ChapterData page, List<ChapterData> orderedPages) {
    if (_selectionMode) {
      _togglePageSelection(page);
      return;
    }

    final pageIndex = orderedPages.indexWhere(
      (item) => item.stableId == page.stableId,
    );
    if (pageIndex < 0) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        settings: RouteSettings(
          name: 'vocabulary:${widget.book.id}:${page.stableId}',
        ),
        builder: (_) => ChapterPage(
          store: widget.store,
          book: widget.book,
          chapter: page,
          pages: orderedPages,
          pageIndex: pageIndex,
        ),
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
          hintText: 'Search pages...',
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

  Widget _pageTile(ChapterData page, List<ChapterData> orderedPages) {
    final selected = _selectedPageIds.contains(page.stableId);
    return SizedBox(
      height: 88,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openPage(page, orderedPages),
          onLongPress: () => _togglePageSelection(page),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.fromLTRB(12, 5, 8, 5),
            leading: _selectionMode
                ? Icon(
                    selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: selected ? Theme.of(context).colorScheme.primary : Colors.black38,
                    size: 27,
                  )
                : Container(
                    width: 42,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F1EC),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.description_outlined, color: Color(0xFF356859)),
                  ),
            title: Text(
              page.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text('${page.words.length} distinct words'),
            trailing: _selectionMode
                ? const SizedBox(width: 4)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PlayButton(
                        store: widget.store,
                        title: page.title,
                        chapters: [page],
                        size: 30,
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Page options',
                        onSelected: (value) {
                          if (value == 'rename') _rename(page);
                          if (value == 'delete') _confirmDeletePages([page]);
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        // Keep image navigation in original scan/import order. The visible
        // directory is alphabetically sorted separately for A–Z browsing.
        final readingOrderPages = List<ChapterData>.from(widget.book.pages);
        final visiblePages = rankAndSortByName<ChapterData>(
          widget.book.pages,
          (page) => page.title,
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
              _selectionMode
                  ? '${_selectedPageIds.length} selected'
                  : widget.book.name,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            actions: _selectionMode
                ? [
                    IconButton(
                      tooltip: 'Delete selected pages',
                      onPressed: () => _confirmDeletePages(
                        widget.book.pages
                            .where((page) => _selectedPageIds.contains(page.stableId))
                            .toList(),
                      ),
                      icon: const Icon(Icons.delete_outline),
                    ),
                    const SizedBox(width: 6),
                  ]
                : [
                    PlayButton(
                      store: widget.store,
                      title: widget.book.name,
                      chapters: widget.book.pages,
                    ),
                    const SizedBox(width: 8),
                  ],
          ),
          floatingActionButton: _selectionMode
              ? null
              : FloatingActionButton.extended(
                  onPressed: busy ? null : _addPage,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Add page'),
                ),
          body: Column(
            children: [
              _searchField(),
              if (!widget.store.dictionary.isLoaded)
                MaterialBanner(
                  content: const Text(
                    'The English–Bangla dictionary is not cached yet. Internet is needed for its first download.',
                  ),
                  leading: const Icon(Icons.cloud_download_outlined),
                  actions: [
                    TextButton(
                      onPressed: busy ? null : _downloadDictionary,
                      child: const Text('Download'),
                    ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${widget.book.pages.length} pages  •  ${widget.store.totalUniqueWords(widget.book)} unique words',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (!_selectionMode)
                      PlayButton(
                        store: widget.store,
                        title: widget.book.name,
                        chapters: widget.book.pages,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: busy
                    ? const Center(child: CircularProgressIndicator())
                    : visiblePages.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(28),
                              child: Text(
                                widget.book.pages.isEmpty
                                    ? 'No pages yet. Add a page using the camera or choose an image from your device.'
                                    : 'No pages match your search.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.black54, fontSize: 15),
                              ),
                            ),
                          )
                        : Stack(
                            children: [
                              Positioned.fill(
                                child: ListView.builder(
                                  controller: _scrollController,
                                  padding: const EdgeInsets.fromLTRB(12, 0, 27, 100),
                                  itemExtent: 88,
                                  itemCount: visiblePages.length,
                                  itemBuilder: (context, index) =>
                                      _pageTile(visiblePages[index], readingOrderPages),
                                ),
                              ),
                              Positioned(
                                right: 1,
                                top: 4,
                                bottom: 8,
                                child: AlphabetFastScroller(
                                  controller: _scrollController,
                                  names: visiblePages.map((page) => page.title).toList(),
                                  itemExtent: 88,
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
