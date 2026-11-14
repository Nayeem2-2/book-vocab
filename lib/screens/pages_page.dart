import 'dart:async';

import 'package:flutter/material.dart';
import 'package:indexed_sliver_list/indexed_sliver_list.dart';

import '../models/book_models.dart';
import '../services/book_store.dart';
import '../services/image_page_importer.dart';
import '../widgets/alphabet_fast_scroller.dart';
import '../widgets/page_details_dialog.dart';
import '../widgets/page_number_fast_scroller.dart';
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
  List<ChapterData>? _orderedPagesCache;
  Timer? _searchDebounce;
  int _listControllerGeneration = 0;
  int? _pendingPageJump;
  int _pageJumpTicket = 0;
  bool _pageJumpScheduled = false;

  bool get _selectionMode => _selectedPageIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreStructureChanged);
  }

  @override
  void didUpdateWidget(covariant PagesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final storeChanged = oldWidget.store != widget.store;
    final bookChanged = oldWidget.book.id != widget.book.id;

    if (storeChanged) {
      oldWidget.store.removeListener(_onStoreStructureChanged);
      widget.store.addListener(_onStoreStructureChanged);
    }

    if (storeChanged || bookChanged) {
      _cachedListData = null;
      _orderedPagesCache = null;
      _selectedPageIds.clear();
      _query = '';
      _searchController.clear();
      _replaceListController();
    }
  }

  void _onStoreStructureChanged() {
    // The page directory is kept mounted underneath the vocabulary route.
    // Invalidate it whenever the book structure changes so it is already
    // current when the user returns.
    _cachedListData = null;
    _orderedPagesCache = null;
    _replaceListController();
  }

  void _refreshPagesAfterVocabularyRoute() {
    if (!mounted) return;
    _cachedListData = null;
    _orderedPagesCache = null;
    // Page additions already notify the store while this route is underneath
    // the vocabulary screen, so the structural listener replaces the indexed
    // controller when needed. Do not reset it again here: returning from a
    // vocabulary page without changing the list should preserve scroll offset.
    setState(() {});
  }

  void _replaceListController() {
    _pageJumpTicket++;
    _pageJumpScheduled = false;
    _pendingPageJump = null;
    final oldController = _scrollController;
    _scrollController = IndexedScrollController();
    _listControllerGeneration++;
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
        _cachedListData = null;
        _message('${added.length} page(s) added and processed.');
        if (mounted) setState(() {});
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

  Future<void> _editPageDetails(ChapterData page) async {
    final details = await showDialog<PageDetailsInput>(
      context: context,
      builder: (_) => PageDetailsDialog(
        page: page,
        pages: widget.book.pages,
      ),
    );
    if (!mounted || details == null) return;

    try {
      await widget.store.updatePageDetails(
        widget.book,
        page,
        name: details.name,
        pageNumber: details.pageNumber,
      );
      if (!mounted) return;
      _cachedListData = null;
      _message('Saved as \"${page.title}\" • Page ${page.pageNumber}');
      setState(() {});
    } catch (error) {
      _message('Could not update page: $error');
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

  Future<void> _openPage(
    ChapterData page,
    List<ChapterData> orderedPages,
  ) async {
    if (_selectionMode) {
      _togglePageSelection(page);
      return;
    }

    final pageIndex = orderedPages.indexWhere(
      (item) => item.stableId == page.stableId,
    );
    if (pageIndex < 0) return;

    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
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

    // Force a fresh numeric order after returning from vocabulary. The store
    // listener normally invalidates this already, but the explicit return
    // refresh also covers route transitions and batched imports.
    _refreshPagesAfterVocabularyRoute();
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
          hintText: 'Search page number or name...',
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

  List<ChapterData> _orderedPagesByNumber() {
    final cached = _orderedPagesCache;
    if (cached != null) return cached;

    // Stable tie-breaker: pages with equal numbers keep scan/import order.
    final indexed = widget.book.pages.asMap().entries.toList(growable: false);
    final numberedPages = indexed.toList()
      ..sort((a, b) {
        final numberOrder = a.value.pageNumber.compareTo(b.value.pageNumber);
        return numberOrder != 0 ? numberOrder : a.key.compareTo(b.key);
      });
    final ordered = numberedPages
        .map((entry) => entry.value)
        .toList(growable: false);
    _orderedPagesCache = ordered;
    return ordered;
  }

  _PagesListData _listData() {
    final cached = _cachedListData;
    if (cached != null && cached.query == _query) return cached;

    // Cached separately from search results: typing a query never re-sorts
    // thousands of page records. The order remains number first, scan order
    // for ties, and never mutates book.pages itself.
    final orderedPages = _orderedPagesByNumber();

    final normalizedQuery = _query.trim();
    List<ChapterData> visiblePages;
    final requestedNumber = int.tryParse(normalizedQuery);
    if (normalizedQuery.isEmpty) {
      visiblePages = orderedPages;
    } else if (requestedNumber != null) {
      final numberMatches = orderedPages
          .where((page) => page.pageNumber == requestedNumber)
          .toList(growable: false);
      visiblePages = numberMatches.isNotEmpty
          ? numberMatches
          : rankAndSortByName<ChapterData>(
              orderedPages,
              (page) => page.title,
              normalizedQuery,
            );
    } else {
      visiblePages = rankAndSortByName<ChapterData>(
        orderedPages,
        (page) => page.title,
        normalizedQuery,
      );
    }

    final data = _PagesListData(
      query: _query,
      orderedPages: orderedPages,
      visiblePages: visiblePages,
      visiblePageNumbers: visiblePages
          .map((page) => page.pageNumber)
          .toList(growable: false),
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
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F1EC),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${page.pageNumber}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF356859),
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
            title: Text(
              page.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text('Page number ${page.pageNumber}  •  ${page.words.length} distinct words'),
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
                          if (value == 'edit') _editPageDetails(page);
                          if (value == 'delete') _confirmDeletePages([page]);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'edit',
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.edit_outlined),
                              title: Text('Edit name & number'),
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

  void _queuePageListJump(int index) {
    final itemCount = _listData().visiblePages.length;
    if (itemCount == 0 || !_scrollController.hasClients) return;
    _pendingPageJump = index.clamp(0, itemCount - 1).toInt();
    if (_pageJumpScheduled) return;

    _pageJumpScheduled = true;
    final ticket = _pageJumpTicket;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageJumpScheduled = false;
      if (!mounted || ticket != _pageJumpTicket ||
          !_scrollController.hasClients) {
        return;
      }
      final target = _pendingPageJump;
      if (target == null) return;
      // Coalesce all finger updates received during one frame into a single
      // indexed jump. This keeps the slider responsive with thousands of pages.
      unawaited(_scrollController.jumpToIndex(target).catchError((_) {}));
    });
  }

  void _settlePageListJump(int index) {
    final itemCount = _listData().visiblePages.length;
    if (!mounted || itemCount == 0 || !_scrollController.hasClients) return;
    // Invalidate any queued per-frame jump and perform one short, restrained
    // animation to settle exactly on the final requested page.
    _pageJumpTicket++;
    _pageJumpScheduled = false;
    _pendingPageJump = null;
    final target = index.clamp(0, itemCount - 1).toInt();
    unawaited(
      _scrollController
          .animateToIndex(
            target,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOutCubic,
            alignment: 0,
          )
          .catchError((_) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final listData = _listData();
        final orderedPages = listData.orderedPages;
        final visiblePages = listData.visiblePages;

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
                                  key: ValueKey('page-list:${widget.book.id}:${visiblePages.length}:${_query}:$_listControllerGeneration'),
                                  controller: _scrollController,
                                  padding: const EdgeInsets.fromLTRB(12, 0, 42, 100),
                                  itemCount: visiblePages.length,
                                  estimatedItemExtent: 88,
                                  addAutomaticKeepAlives: false,
                                  itemBuilder: (context, index) => _pageTile(
                                    visiblePages[index],
                                    orderedPages,
                                  ),
                                ),
                              ),
                              if (!_selectionMode && visiblePages.length > 1)
                                Positioned(
                                  right: 1,
                                  top: 8,
                                  bottom: 104,
                                  child: PageNumberFastScroller(
                                    controller: _scrollController,
                                    itemCount: visiblePages.length,
                                    pageNumbers: listData.visiblePageNumbers,
                                    onIndexChanged: _queuePageListJump,
                                    onDragEnd: _settlePageListJump,
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
    required this.orderedPages,
    required this.visiblePages,
    required this.visiblePageNumbers,
  });

  final String query;
  final List<ChapterData> orderedPages;
  final List<ChapterData> visiblePages;
  final List<int> visiblePageNumbers;
}
