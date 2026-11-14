import 'dart:async';

import 'package:flutter/material.dart';
import 'package:indexed_sliver_list/indexed_sliver_list.dart';

import '../models/book_models.dart';
import '../services/book_store.dart';
import '../services/image_page_importer.dart';
import '../widgets/alphabet_fast_scroller.dart';
import '../widgets/name_input_dialog.dart';
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
  IndexedScrollController _scrollController = IndexedScrollController();
  final Set<String> _selectedPageIds = <String>{};
  String _query = '';
  bool busy = false;
  _PagesListData? _cachedListData;
  Timer? _searchDebounce;

  bool get _selectionMode => _selectedPageIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreStructureChanged);
  }

  @override
  void didUpdateWidget(covariant PagesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreStructureChanged);
      widget.store.addListener(_onStoreStructureChanged);
      _cachedListData = null;
      _replaceListController();
    }
  }

  void _onStoreStructureChanged() {
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

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _reloadBundledDictionary() async {
    setState(() => busy = true);
    try {
      await widget.store.dictionary.load();
      _message('Bundled English–Bangla dictionary loaded.');
    } catch (error) {
      _message(
        'Could not load the bundled dictionary. Verify '
        'assets/dictionary/E2Bdatabase.json and its pubspec.yaml asset entry. '
        'Details: $error',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addPage() async {
    setState(() => busy = true);
    try {
      final added = await addImagePagesFromSource(
        context: context,
        store: widget.store,
        book: widget.book,
      );
      if (added.isNotEmpty) {
        _message('${added.length} page(s) added and processed.');
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
    final name = await showDialog<String>(
      context: context,
      builder: (_) => NameInputDialog(
        title: 'Rename page',
        label: 'Page name',
        initialValue: page.title,
        submitLabel: 'Save',
      ),
    );
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
          hintText: 'Search pages...',
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

  Map<String, List<ChapterData>> _groupPagesByInitial(
    List<ChapterData> pages,
  ) {
    final groups = <String, List<ChapterData>>{};
    for (final page in pages) {
      final trimmed = page.title.trim();
      final initial = trimmed.isEmpty ? '#' : trimmed[0].toUpperCase();
      final letter = isEnglishAlphabetLetter(initial) ? initial : '#';
      groups.putIfAbsent(letter, () => <ChapterData>[]).add(page);
    }
    return groups;
  }

  Widget _letterHeader(String letter) {
    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 2),
        child: Row(
          children: [
            Text(
              letter,
              style: const TextStyle(
                color: Color(0xFF356859),
                fontSize: 13,
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

  _PagesListData _listData() {
    final cached = _cachedListData;
    if (cached != null && cached.query == _query) return cached;

    // This order is used for Previous/Next after entering from the Pages list.
    final alphabeticalPages = List<ChapterData>.from(widget.book.pages)
      ..sort((a, b) => a.title.trim().toLowerCase().compareTo(
            b.title.trim().toLowerCase(),
          ));
    final visiblePages = _query.trim().isEmpty
        ? alphabeticalPages
        : rankAndSortByName<ChapterData>(
            widget.book.pages,
            (page) => page.title,
            _query,
          );
    final groupedPages = _groupPagesByInitial(visiblePages);
    final rows = <Object>[];
    final sectionIndexes = <String, int>{};
    for (final group in groupedPages.entries) {
      sectionIndexes[group.key] = rows.length;
      rows.add(group.key);
      rows.addAll(group.value);
    }
    final indexLetters = groupedPages.keys
        .where((letter) => isEnglishAlphabetLetter(letter))
        .toList(growable: false);

    final data = _PagesListData(
      query: _query,
      alphabeticalPages: alphabeticalPages,
      visiblePages: visiblePages,
      rows: rows,
      sectionIndexes: sectionIndexes,
      indexLetters: indexLetters,
    );
    _cachedListData = data;
    return data;
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
        // Cached separately from selection state so long-press/tap selection
        // never repeats the full-page sort and grouping operation.
        final listData = _listData();
        final alphabeticalPages = listData.alphabeticalPages;
        final visiblePages = listData.visiblePages;
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
                : [],
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
              ValueListenableBuilder<bool>(
                valueListenable: widget.store.dictionary.loadedListenable,
                builder: (context, dictionaryLoaded, _) {
                  if (dictionaryLoaded) return const SizedBox.shrink();
                  return MaterialBanner(
                    content: const Text(
                      'The bundled English–Bangla dictionary could not be loaded. Check that E2Bdatabase.json is in assets/dictionary and registered in pubspec.yaml.',
                    ),
                    leading: const Icon(Icons.menu_book_outlined),
                    actions: [
                      TextButton(
                        onPressed: busy ? null : _reloadBundledDictionary,
                        child: const Text('Retry'),
                      ),
                    ],
                  );
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: ValueListenableBuilder<int>(
                        valueListenable: widget.store.wordStateRevision,
                        builder: (context, _, __) => FutureBuilder<void>(
                          future: widget.store.ensureBookWordCache(widget.book),
                          builder: (context, snapshot) {
                            final summary = widget.store.hasBookWordCache(widget.book)
                                ? '${widget.book.pages.length} pages  •  ${widget.store.totalUniqueWords(widget.book)} unique words'
                                : '${widget.book.pages.length} pages  •  Preparing word statistics…';
                            return Text(
                              summary,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        ),
                      ),
                    ),
                    if (!_selectionMode)
                      PlayButton(
                        store: widget.store,
                        title: widget.book.name,
                        chapters: widget.book.pages,
                        book: widget.book,
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
                                child: IndexedListView(
                                  controller: _scrollController,
                                  padding: const EdgeInsets.fromLTRB(12, 0, 27, 100),
                                  itemCount: rows.length,
                                  estimatedItemExtent: 88,
                                  addAutomaticKeepAlives: false,
                                  itemBuilder: (context, index) {
                                    final row = rows[index];
                                    return row is String
                                        ? _letterHeader(row)
                                        : _pageTile(
                                            row as ChapterData,
                                            alphabeticalPages,
                                          );
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
                                      if (target == null ||
                                          !_scrollController.hasClients) {
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


class _PagesListData {
  const _PagesListData({
    required this.query,
    required this.alphabeticalPages,
    required this.visiblePages,
    required this.rows,
    required this.sectionIndexes,
    required this.indexLetters,
  });

  final String query;
  final List<ChapterData> alphabeticalPages;
  final List<ChapterData> visiblePages;
  final List<Object> rows;
  final Map<String, int> sectionIndexes;
  final List<String> indexLetters;
}
