import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:indexed_sliver_list/indexed_sliver_list.dart';

import '../models/book_models.dart';
import '../services/book_store.dart';
import '../services/view_preferences_service.dart';
import '../services/image_page_importer.dart';
import '../widgets/page_details_dialog.dart';
import '../widgets/alphabet_fast_scroller.dart';
import '../widgets/page_number_fast_scroller.dart';
import '../widgets/play_widgets.dart';
import '../widgets/view_settings_sheet.dart';
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
  BrowseLayout _viewLayout = BrowseLayout.list;
  int _listSize = 3;
  int _gridSize = 3;
  int get _viewSize => _viewLayout == BrowseLayout.list ? _listSize : _gridSize;

  bool get _selectionMode => _selectedPageIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreStructureChanged);
    _loadViewPreferences();
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
        description: details.description,
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
              (page) => '${page.title} ${page.description}',
              normalizedQuery,
            );
    } else {
      visiblePages = rankAndSortByName<ChapterData>(
        orderedPages,
        (page) => '${page.title} ${page.description}',
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

  Future<void> _loadViewPreferences() async {
    final preference = await ViewPreferencesService.load('pages');
    if (!mounted) return;
    setState(() {
      _viewLayout = preference.layout;
      _listSize = preference.listSize;
      _gridSize = preference.gridSize;
    });
  }

  void _updateViewPreference(BrowseViewPreference preference) {
    setState(() {
      _viewLayout = preference.layout;
      _listSize = preference.listSize;
      _gridSize = preference.gridSize;
      _cachedListData = null;
    });
    unawaited(ViewPreferencesService.save('pages', preference));
  }

  Future<void> _openViewSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => ViewSettingsSheet(
        preference: BrowseViewPreference(
          layout: _viewLayout, listSize: _listSize, gridSize: _gridSize,
        ),
        description: 'Customize how your scanned pages are displayed.',
        onChanged: _updateViewPreference,
        previewBuilder: _pageSettingsPreview,
      ),
    );
  }

  Widget _pageSettingsPreview(BrowseViewPreference preference) {
    final page = widget.book.pages.isNotEmpty
        ? widget.book.pages.first
        : ChapterData(title: 'Sample page', pageRange: '', words: const [], pageNumber: 1,
            description: 'A short page description appears here.');
    if (preference.layout == BrowseLayout.list) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(8 + preference.size.toDouble()),
          child: Row(
            children: [
              Container(
                width: (40 + preference.size * 2).toDouble(),
                height: (40 + preference.size * 2).toDouble(),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text('${page.pageNumber}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(page.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(page.description.isEmpty ? 'Page description' : page.description,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(8 + preference.size.toDouble()),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(radius: 13, child: Text('${page.pageNumber}',
                  style: const TextStyle(fontSize: 11))),
              const Spacer(),
              const Icon(Icons.more_horiz, size: 18),
            ]),
            const SizedBox(height: 8),
            Container(
              height: (44 + preference.size * 3).toDouble(),
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.image_outlined),
            ),
            const SizedBox(height: 8),
            Text(page.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(page.description.isEmpty ? 'Page description' : page.description,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _pageTile(ChapterData page, List<ChapterData> orderedPages) {
    final selected = _selectedPageIds.contains(page.stableId);
    final height = 88.0 + (_viewSize * 12.0);
    return SizedBox(
      height: height,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openPage(page, orderedPages),
          onLongPress: () => _togglePageSelection(page),
          child: ListTile(
            dense: _viewSize <= 2,
            contentPadding: EdgeInsets.fromLTRB(12, 4, 5, 4 + _viewSize.toDouble()),
            leading: Container(
              width: (44 + _viewSize * 2).toDouble(),
              height: (44 + _viewSize * 2).toDouble(),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                '${page.pageNumber}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontSize: 15 + _viewSize.toDouble() * 0.4,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            title: Text(
              page.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14 + _viewSize * 0.35),
            ),
            subtitle: Text(
              page.description.trim().isNotEmpty
                  ? page.description.trim()
                  : '${page.words.length} vocabulary words',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _selectionMode
                ? Icon(
                    selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: selected ? Theme.of(context).colorScheme.primary : Colors.black38,
                    size: 25,
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PlayButton(
                        store: widget.store,
                        title: page.title,
                        chapters: [page],
                        size: 30,
                      ),
                      _pageOptionsMenu(page),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  PopupMenuButton<String> _pageOptionsMenu(ChapterData page) =>
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
              title: Text('Edit page details'),
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
      );

  Widget _pageGridTile(ChapterData page, List<ChapterData> orderedPages) {
    final selected = _selectedPageIds.contains(page.stableId);
    final imagePath = page.imagePath;
    final hasImage = imagePath != null && imagePath.isNotEmpty && File(imagePath).existsSync();
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openPage(page, orderedPages),
        onLongPress: () => _togglePageSelection(page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 6),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                    child: FittedBox(child: Text('${page.pageNumber}',
                        style: const TextStyle(fontWeight: FontWeight.w800))),
                  ),
                  const Spacer(),
                  if (_selectionMode)
                    Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                        size: 21, color: selected ? Theme.of(context).colorScheme.primary : null)
                  else
                    _pageOptionsMenu(page),
                ],
              ),
            ),
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 9),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: hasImage
                    ? Image.file(File(imagePath), fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.image_not_supported_outlined)))
                    : const Center(child: Icon(Icons.image_outlined, size: 34)),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(11, 9, 11, 9 + _viewSize.toDouble()),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(page.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13 + _viewSize * 0.3)),
                  const SizedBox(height: 3),
                  Text(
                    page.description.trim().isNotEmpty
                        ? page.description.trim()
                        : '${page.words.length} vocabulary words',
                    maxLines: _viewSize >= 4 ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
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
                : [
                    PopupMenuButton<String>(
                      tooltip: 'More options',
                      icon: const Icon(Icons.more_vert),
                      onSelected: (value) {
                        if (value == 'view') _openViewSettings();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'view',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.dashboard_customize_outlined),
                            title: Text('View options'),
                          ),
                        ),
                      ],
                    ),
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
                        : _viewLayout == BrowseLayout.grid
                            ? GridView.builder(
                                key: ValueKey('page-grid:${widget.book.id}:${visiblePages.length}:${_query}'),
                                padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
                                itemCount: visiblePages.length,
                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: _viewSize == 1 ? 3 : (_viewSize == 5 ? 1 : 2),
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  mainAxisExtent: 190.0 + (_viewSize * 18.0),
                                ),
                                itemBuilder: (context, index) => _pageGridTile(
                                  visiblePages[index], orderedPages,
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
                                      estimatedItemExtent: 100.0 + (_viewSize * 12.0),
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
