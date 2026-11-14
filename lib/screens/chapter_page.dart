import 'dart:async';

import 'package:flutter/material.dart';
import 'package:indexed_sliver_list/indexed_sliver_list.dart';

import '../models/book_models.dart';
import '../services/book_store.dart';
import '../services/image_page_importer.dart';
import '../widgets/alphabet_fast_scroller.dart';
import '../widgets/play_widgets.dart';
import 'image_viewer_page.dart';

class ChapterPage extends StatefulWidget {
  const ChapterPage({
    super.key,
    required this.store,
    required this.book,
    required this.chapter,
    this.pages = const [],
    this.pageIndex = 0,
  });

  final BookStore store;
  final BookData book;
  final ChapterData chapter;

  /// Ordering is intentional: Pages-list entry supplies alphabetical order;
  /// adding a page from this screen switches this list to scan/import order.
  final List<ChapterData> pages;
  final int pageIndex;

  @override
  State<ChapterPage> createState() => _ChapterPageState();
}

class _ChapterPageState extends State<ChapterPage> {
  bool showKnown = false;
  String query = '';
  bool _addingPage = false;

  late List<ChapterData> _navigationPages;
  late int _currentIndex;

  IndexedScrollController _wordScrollController = IndexedScrollController();
  final TextEditingController _queryController = TextEditingController();
  Timer? _searchDebounce;
  final Map<String, Map<String, List<WordEntry>>> _groupedWordCache = {};
  _VocabularyListModel? _visibleListCache;
  String? _visibleListCacheKey;

  bool get _isImageBook => widget.book.isImageBook;

  ChapterData get _currentChapter {
    if (_isImageBook && _navigationPages.isNotEmpty) {
      final safeIndex =
          _currentIndex.clamp(0, _navigationPages.length - 1).toInt();
      return _navigationPages[safeIndex];
    }
    return widget.chapter;
  }

  @override
  void initState() {
    super.initState();
    _navigationPages = widget.pages.isNotEmpty
        ? List<ChapterData>.from(widget.pages)
        : <ChapterData>[widget.chapter];
    _currentIndex = widget.pageIndex
        .clamp(0, _navigationPages.isEmpty ? 0 : _navigationPages.length - 1)
        .toInt();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _wordScrollController.dispose();
    _queryController.dispose();
    super.dispose();
  }

  void _resetWordScrollController() {
    final oldController = _wordScrollController;
    _wordScrollController = IndexedScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      oldController.dispose();
    });
  }

  void _scrollWordsToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_wordScrollController.hasClients) {
        _wordScrollController.jumpTo(0);
      }
    });
  }

  void _navigateToPage(int targetIndex) {
    if (!_isImageBook ||
        targetIndex < 0 ||
        targetIndex >= _navigationPages.length ||
        targetIndex == _currentIndex) {
      return;
    }

    _searchDebounce?.cancel();
    _resetWordScrollController();
    setState(() {
      _currentIndex = targetIndex;
      query = '';
      _queryController.clear();
    });
    _scrollWordsToTop();
  }

  Future<void> _openImageViewer() async {
    final pages = List<ChapterData>.from(_navigationPages);
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute<String>(
        settings: RouteSettings(name: 'image-viewer:${widget.book.id}'),
        builder: (_) => ImageViewerPage(
          book: widget.book,
          pages: pages,
          initialPageIndex: _currentIndex,
        ),
      ),
    );

    if (!mounted || result == null) return;
    final returnedIndex = _navigationPages.indexWhere(
      (page) => page.stableId == result,
    );
    if (returnedIndex >= 0 && returnedIndex != _currentIndex) {
      _searchDebounce?.cancel();
      _resetWordScrollController();
      setState(() => _currentIndex = returnedIndex);
      _scrollWordsToTop();
    }
  }

  Future<void> _addPageFromVocabulary() async {
    if (_addingPage) return;
    setState(() => _addingPage = true);
    try {
      final added = await addImagePagesFromSource(
        context: context,
        store: widget.store,
        book: widget.book,
      );
      if (!mounted || added.isEmpty) return;

      final scanOrder = List<ChapterData>.from(widget.book.pages);
      final newestId = added.last.stableId;
      final newestIndex = scanOrder.indexWhere(
        (page) => page.stableId == newestId,
      );
      if (newestIndex >= 0) {
        _searchDebounce?.cancel();
        _resetWordScrollController();
        setState(() {
          _navigationPages = scanOrder;
          _currentIndex = newestIndex;
          query = '';
          _queryController.clear();
        });
        _scrollWordsToTop();
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${added.length} page(s) added and processed.')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add page: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _addingPage = false);
    }
  }

  void _scheduleWordSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 140), () {
      if (!mounted) return;
      final nextQuery = value.trim();
      if (nextQuery == query) return;
      _resetWordScrollController();
      setState(() => query = nextQuery);
    });
  }

  void _clearWordSearch() {
    _searchDebounce?.cancel();
    _queryController.clear();
    _resetWordScrollController();
    setState(() => query = '');
  }

  Map<String, List<WordEntry>> _groupedWordsFor(ChapterData chapter) {
    final cacheKey = chapter.stableId;
    final cached = _groupedWordCache.remove(cacheKey);
    if (cached != null &&
        cached.values.fold<int>(0, (sum, group) => sum + group.length) ==
            chapter.words.length) {
      _groupedWordCache[cacheKey] = cached;
      return cached;
    }

    // Normalize each word once before sorting instead of allocating a new
    // lowercase/trimmed string for every comparator invocation.
    final sortable = chapter.words
        .map((entry) => _SortableWordEntry(
              entry,
              entry.word.trim().toLowerCase(),
            ))
        .toList()
      ..sort((a, b) => a.sortKey.compareTo(b.sortKey));

    final groups = <String, List<WordEntry>>{};
    for (final item in sortable) {
      final word = item.entry.word.trim();
      final initial = word.isEmpty ? '#' : word[0].toUpperCase();
      final letter = isEnglishAlphabetLetter(initial) ? initial : '#';
      groups.putIfAbsent(letter, () => <WordEntry>[]).add(item.entry);
    }

    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a == '#') return 1;
        if (b == '#') return -1;
        return a.compareTo(b);
      });
    final ordered = <String, List<WordEntry>>{
      for (final key in keys) key: groups[key]!,
    };
    _groupedWordCache[cacheKey] = ordered;

    // Only the current and a few recently visited pages need a sorted copy.
    // The original page data remains in scan/import order in BookStore.
    while (_groupedWordCache.length > 3) {
      _groupedWordCache.remove(_groupedWordCache.keys.first);
    }
    return ordered;
  }

  bool _matchesWord(WordEntry entry, String normalizedQuery) {
    if (normalizedQuery.isEmpty) return true;
    if (entry.word.toLowerCase().contains(normalizedQuery)) return true;
    return entry.meanings.any(
      (meaning) => meaning.toLowerCase().contains(normalizedQuery),
    );
  }

  _VocabularyListModel _visibleListFor(ChapterData chapter) {
    final normalizedQuery = query.trim().toLowerCase();
    final cacheKey = '${chapter.stableId}|${chapter.words.length}|$normalizedQuery|$_isImageBook';
    final cached = _visibleListCache;
    if (cached != null && _visibleListCacheKey == cacheKey) return cached;

    final sections = <_VocabularySection>[];
    final letterIndexes = <String, int>{};
    var itemCount = 0;

    if (_isImageBook) {
      final groups = _groupedWordsFor(chapter);
      for (final group in groups.entries) {
        final visibleWords = normalizedQuery.isEmpty
            ? group.value
            : group.value
                .where((entry) => _matchesWord(entry, normalizedQuery))
                .toList(growable: false);
        if (visibleWords.isEmpty) continue;

        final headerLetter = group.key == '#' ? null : group.key;
        if (headerLetter != null) letterIndexes[headerLetter] = itemCount;
        sections.add(_VocabularySection(
          letter: headerLetter,
          words: visibleWords,
          startIndex: itemCount,
        ));
        itemCount += visibleWords.length + (headerLetter == null ? 0 : 1);
      }
    } else {
      // JSON books deliberately preserve their original source order.
      final visibleWords = normalizedQuery.isEmpty
          ? chapter.words
          : chapter.words
              .where((entry) => _matchesWord(entry, normalizedQuery))
              .toList(growable: false);
      if (visibleWords.isNotEmpty) {
        sections.add(_VocabularySection(
          letter: null,
          words: visibleWords,
          startIndex: 0,
        ));
        itemCount = visibleWords.length;
      }
    }

    final model = _VocabularyListModel(
      sections: sections,
      letterIndexes: letterIndexes,
      itemCount: itemCount,
    );
    _visibleListCacheKey = cacheKey;
    _visibleListCache = model;
    return model;
  }

  Widget _letterHeader(String letter) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 8, 8),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFE4EFE8),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              letter,
              style: const TextStyle(
                color: Color(0xFF356859),
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(
              color: const Color(0xFF356859).withOpacity(0.16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wordCard(WordEntry entry) {
    return ValueListenableBuilder<WordState>(
      valueListenable: widget.store.wordStateListenable(entry.word),
      builder: (context, state, _) {
        if (state == WordState.known && !showKnown) {
          return const SizedBox.shrink();
        }
        return _buildWordCard(entry, state);
      },
    );
  }

  Widget _buildWordCard(WordEntry entry, WordState state) {
    final badgeColor = state == WordState.known
        ? const Color(0xFF27845B)
        : state == WordState.showAgain
            ? const Color(0xFFD97706)
            : Colors.transparent;
    final badgeText = state == WordState.known
        ? 'KNOWN'
        : state == WordState.showAgain
            ? 'SHOW AGAIN'
            : '';

    return Dismissible(
      key: ValueKey('${_currentChapter.stableId}:${entry.word}'),
      direction: state == WordState.known
          ? DismissDirection.startToEnd
          : DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        color: Colors.orange.withOpacity(0.2),
        child: const Icon(Icons.replay, color: Color(0xFFD97706)),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: const Color(0xFF27845B).withOpacity(0.2),
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              'Known',
              style: TextStyle(
                color: Color(0xFF27845B),
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: 8),
            Icon(Icons.check_circle, color: Color(0xFF27845B)),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        if (state == WordState.known &&
            direction == DismissDirection.startToEnd) {
          widget.store.setWordState(entry.word, WordState.showAgain);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Moved to Show Again'),
              duration: Duration(milliseconds: 600),
            ),
          );
        } else if (state != WordState.known &&
            direction == DismissDirection.endToStart) {
          widget.store.setWordState(entry.word, WordState.known);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.auto_awesome, color: Colors.amber, size: 18),
                  SizedBox(width: 8),
                  Text('✨ Marked as Known!'),
                ],
              ),
              duration: Duration(milliseconds: 800),
              backgroundColor: Color(0xFF27845B),
            ),
          );
        }
        return false;
      },
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 8, 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.word,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      entry.meanings.isEmpty
                          ? 'বাংলা অর্থ পাওয়া যায়নি'
                          : entry.meanings.join('  •  '),
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.45,
                        color: entry.meanings.isEmpty
                            ? Colors.black38
                            : const Color(0xFF426B59),
                      ),
                    ),
                    if (badgeText.isNotEmpty &&
                        (showKnown || state == WordState.showAgain))
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          badgeText,
                          style: TextStyle(
                            color: badgeColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: state == WordState.known ? 'Mark unknown' : 'Mark known',
                onPressed: () {
                  final next = state == WordState.known
                      ? WordState.unknown
                      : WordState.known;
                  widget.store.setWordState(entry.word, next);
                  if (next == WordState.known) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Row(
                          children: [
                            Icon(Icons.auto_awesome,
                                color: Colors.amber, size: 18),
                            SizedBox(width: 8),
                            Text('✨ Marked as Known!'),
                          ],
                        ),
                        duration: Duration(milliseconds: 800),
                        backgroundColor: Color(0xFF27845B),
                      ),
                    );
                  }
                },
                icon: Icon(
                  state == WordState.known
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked,
                  color: state == WordState.known
                      ? const Color(0xFF27845B)
                      : Colors.black38,
                  size: 28,
                ),
              ),
              IconButton(
                tooltip: 'Mark as Show Again',
                onPressed: () {
                  widget.store.setWordState(entry.word, WordState.showAgain);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Flagged for Show Again'),
                      duration: Duration(milliseconds: 600),
                    ),
                  );
                },
                icon: Icon(
                  state == WordState.showAgain
                      ? Icons.replay_circle_filled_rounded
                      : Icons.replay,
                  color: state == WordState.showAgain
                      ? const Color(0xFFD97706)
                      : Colors.black38,
                  size: 26,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageNavigation() {
    if (!_isImageBook || _navigationPages.isEmpty) {
      return const SizedBox.shrink();
    }

    final isFirst = _currentIndex <= 0;
    final isLast = _currentIndex >= _navigationPages.length - 1;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _roundNavigationButton(
          icon: Icons.chevron_left_rounded,
          tooltip: 'Previous page',
          enabled: !isFirst,
          onPressed: () => _navigateToPage(_currentIndex - 1),
        ),
        const SizedBox(width: 10),
        if (isLast)
          _roundNavigationButton(
            icon: Icons.add_photo_alternate_outlined,
            tooltip: 'Add page',
            enabled: !_addingPage,
            onPressed: _addPageFromVocabulary,
          )
        else
          _roundNavigationButton(
            icon: Icons.chevron_right_rounded,
            tooltip: 'Next page',
            enabled: true,
            onPressed: () => _navigateToPage(_currentIndex + 1),
          ),
      ],
    );
  }

  Widget _roundNavigationButton({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    final foreground = enabled ? const Color(0xFF24352C) : Colors.black26;
    return Material(
      color: Colors.white.withOpacity(enabled ? 0.97 : 0.42),
      shape: const CircleBorder(),
      elevation: enabled ? 2 : 0,
      child: IconButton(
        tooltip: tooltip,
        onPressed: enabled ? onPressed : null,
        icon: _addingPage && tooltip == 'Add page'
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 30, color: foreground),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentChapter = _currentChapter;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          currentChapter.title,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (currentChapter.imagePath != null)
            IconButton(
              tooltip: 'View scanned page image',
              onPressed: _openImageViewer,
              icon: const Icon(Icons.image_outlined),
            ),
          PlayButton(
            store: widget.store,
            title: currentChapter.title,
            chapters: [currentChapter],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  children: [
                    TextField(
                      controller: _queryController,
                      onChanged: _scheduleWordSearch,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search words or meanings',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: _clearWordSearch,
                                icon: const Icon(Icons.close),
                              ),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide:
                              const BorderSide(color: Color(0xFFE8ECE7)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide:
                              const BorderSide(color: Color(0xFFE8ECE7)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ValueListenableBuilder<int>(
                      valueListenable: widget.store.wordStateRevision,
                      builder: (context, _, __) {
                        final counts = widget.store.practiceCounts([currentChapter]);
                        final total = widget.store.uniqueWordCount([currentChapter]);
                        final known = (total - counts.total).clamp(0, total);
                        return Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${counts.total} unknown/review  •  $known known',
                                style: const TextStyle(
                                  color: Colors.black54,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const Text(
                              'Show known',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            Switch(
                              value: showKnown,
                              onChanged: (value) =>
                                  setState(() => showKnown = value),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Builder(
                  builder: (context) {
                    final rows = _visibleListFor(currentChapter);
                    final letters = rows.letterIndexes.keys.toList(growable: false);

                    return Stack(
                      children: [
                        Positioned.fill(
                          child: IndexedListView(
                            controller: _wordScrollController,
                            padding: const EdgeInsets.fromLTRB(16, 4, 42, 112),
                            estimatedItemExtent: 112,
                            itemCount: rows.itemCount,
                            addAutomaticKeepAlives: false,
                            itemBuilder: (context, index) {
                              final row = rows.rowAt(index, currentChapter.stableId);
                              final child = row.letter != null
                                  ? _letterHeader(row.letter!)
                                  : Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 8),
                                      child: _wordCard(row.entry!),
                                    );
                              return KeyedSubtree(key: row.key, child: child);
                            },
                          ),
                        ),
                        if (_isImageBook && letters.isNotEmpty)
                          Positioned(
                            right: 1,
                            top: 4,
                            bottom: 8,
                            child: AlphabetFastScroller(
                              controller: _wordScrollController,
                              names: letters,
                              itemExtent: 0,
                              onLetterSelected: (letter) {
                                final target = rows.letterIndexes[letter];
                                if (target != null &&
                                    _wordScrollController.hasClients) {
                                  unawaited(_wordScrollController.jumpToIndex(
                                    target,
                                    alignment: 0,
                                  ));
                                }
                              },
                            ),
                          ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ValueListenableBuilder<int>(
                              valueListenable: widget.store.wordStateRevision,
                              builder: (context, _, __) {
                                final counts =
                                    widget.store.practiceCounts([currentChapter]);
                                final empty = rows.itemCount == 0 ||
                                    (query.isEmpty && !showKnown && counts.total == 0);
                                if (!empty) return const SizedBox.shrink();
                                final message = rows.itemCount == 0
                                    ? (query.isNotEmpty
                                        ? 'No matching words.'
                                        : showKnown
                                            ? 'This chapter has no words.'
                                            : 'All words in this chapter are marked known.')
                                    : 'All words in this chapter are marked known.';
                                return ColoredBox(
                                  color: Theme.of(context).scaffoldBackgroundColor,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(28),
                                      child: Text(
                                        message,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.black54,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
          if (_isImageBook)
            Positioned(
              left: 16,
              bottom: 16,
              child: _MarkAllWordsSlider(
                key: ValueKey('mark-all:${currentChapter.stableId}'),
                store: widget.store,
                chapter: currentChapter,
              ),
            ),
          if (_isImageBook)
            Positioned(
              right: 16,
              bottom: 16,
              child: _pageNavigation(),
            ),
        ],
      ),
    );
  }

}


class _SortableWordEntry {
  const _SortableWordEntry(this.entry, this.sortKey);
  final WordEntry entry;
  final String sortKey;
}

class _VocabularySection {
  const _VocabularySection({
    required this.letter,
    required this.words,
    required this.startIndex,
  });

  final String? letter;
  final List<WordEntry> words;
  final int startIndex;
  int get rowCount => words.length + (letter == null ? 0 : 1);
}

class _VocabularyListModel {
  const _VocabularyListModel({
    required this.sections,
    required this.letterIndexes,
    required this.itemCount,
  });

  final List<_VocabularySection> sections;
  final Map<String, int> letterIndexes;
  final int itemCount;

  _VocabularyRow rowAt(int index, String chapterId) {
    var low = 0;
    var high = sections.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final section = sections[middle];
      if (index < section.startIndex) {
        high = middle - 1;
      } else if (index >= section.startIndex + section.rowCount) {
        low = middle + 1;
      } else {
        final localIndex = index - section.startIndex;
        if (section.letter != null && localIndex == 0) {
          return _VocabularyRow.header(section.letter!);
        }
        final wordIndex = localIndex - (section.letter == null ? 0 : 1);
        return _VocabularyRow.word(chapterId, section.words[wordIndex]);
      }
    }
    throw RangeError.index(index, sections, 'index');
  }
}

class _VocabularyRow {
  const _VocabularyRow._({this.letter, this.entry, required this.key});

  factory _VocabularyRow.header(String letter) => _VocabularyRow._(
        letter: letter,
        key: ValueKey<String>('header:$letter'),
      );

  factory _VocabularyRow.word(String chapterId, WordEntry entry) =>
      _VocabularyRow._(
        entry: entry,
        key: ValueKey<String>(
          'word:$chapterId:${BookStore.normalizeWord(entry.word)}',
        ),
      );

  final String? letter;
  final WordEntry? entry;
  final Key key;
}

/// Keeps slider pointer updates local to this small widget. It never rebuilds
/// the vocabulary list while the thumb is moving.
class _MarkAllWordsSlider extends StatefulWidget {
  const _MarkAllWordsSlider({
    super.key,
    required this.store,
    required this.chapter,
  });

  final BookStore store;
  final ChapterData chapter;

  @override
  State<_MarkAllWordsSlider> createState() => _MarkAllWordsSliderState();
}

class _MarkAllWordsSliderState extends State<_MarkAllWordsSlider> {
  double _value = 0;
  bool _busy = false;

  Future<void> _finish(double value) async {
    if (_busy || value < 0.995) return;
    setState(() => _busy = true);
    try {
      await widget.store.markAllChapterKnown(widget.chapter);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '✨ All eligible words marked known (Show Again protected)!',
          ),
          backgroundColor: Color(0xFF27845B),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _value = 0;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: const Color(0xFF356859).withOpacity(0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 45),
            child: Text(
              _busy ? 'Updating…' : 'Slide to mark all →',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF356859),
              ),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 48,
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
              thumbColor: const Color(0xFF356859),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 22),
              overlayColor: Colors.transparent,
            ),
            child: Slider(
              value: _value,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _value = value),
              onChangeEnd: _finish,
            ),
          ),
        ],
      ),
    );
  }
}
