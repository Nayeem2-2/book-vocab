import 'package:flutter/material.dart';

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
  double _sliderValue = 0.0;
  bool _addingPage = false;

  late List<ChapterData> _navigationPages;
  late int _currentIndex;

  final ScrollController _wordScrollController = ScrollController();
  final TextEditingController _queryController = TextEditingController();
  final Map<String, GlobalKey> _sectionKeys = <String, GlobalKey>{};

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
    _wordScrollController.dispose();
    _queryController.dispose();
    super.dispose();
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

    setState(() {
      _currentIndex = targetIndex;
      query = '';
      _queryController.clear();
      _sectionKeys.clear();
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

      // This entry point is the explicit Add Page action. Switch to the
      // permanent scan/import sequence and open the newest added page.
      final scanOrder = List<ChapterData>.from(widget.book.pages);
      final newestId = added.last.stableId;
      final newestIndex = scanOrder.indexWhere(
        (page) => page.stableId == newestId,
      );
      if (newestIndex >= 0) {
        setState(() {
          _navigationPages = scanOrder;
          _currentIndex = newestIndex;
          query = '';
          _queryController.clear();
          _sectionKeys.clear();
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

  void _scrollToLetter(String letter) {
    final sectionContext = _sectionKeys[letter]?.currentContext;
    if (sectionContext == null) return;
    Scrollable.ensureVisible(
      sectionContext,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      alignment: 0,
    );
  }

  Map<String, List<WordEntry>> _groupWords(List<WordEntry> entries) {
    final sorted = List<WordEntry>.from(entries)
      ..sort((a, b) => a.word.trim().toLowerCase().compareTo(
            b.word.trim().toLowerCase(),
          ));

    final groups = <String, List<WordEntry>>{};
    for (final entry in sorted) {
      final trimmed = entry.word.trim();
      final first = trimmed.isEmpty ? '#' : trimmed[0].toUpperCase();
      final key = RegExp(r'^[A-Z]$').hasMatch(first) ? first : '#';
      groups.putIfAbsent(key, () => <WordEntry>[]).add(entry);
    }

    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a == '#') return 1;
        if (b == '#') return -1;
        return a.compareTo(b);
      });
    return <String, List<WordEntry>>{
      for (final key in keys) key: groups[key]!,
    };
  }

  Widget _wordCard(WordEntry entry) {
    final state = widget.store.getWordState(entry.word);
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
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final currentChapter = _currentChapter;
        final visible = currentChapter.words.where((entry) {
          final state = widget.store.getWordState(entry.word);
          final known = state == WordState.known;
          final matchesStatus = showKnown || !known;
          final normalizedQuery = query.toLowerCase();
          final matchesQuery = query.isEmpty ||
              entry.word.toLowerCase().contains(normalizedQuery) ||
              entry.meanings.any(
                (meaning) => meaning.toLowerCase().contains(normalizedQuery),
              );
          return matchesStatus && matchesQuery;
        }).toList();

        final knownInChapter = currentChapter.words
            .where((word) =>
                widget.store.getWordState(word.word) == WordState.known)
            .length;
        final unknownInChapter = currentChapter.words.length - knownInChapter;

        // OCR vocabulary is grouped alphabetically. JSON chapter vocabulary
        // retains its existing source order to avoid changing imported books.
        final groupedWords = _isImageBook ? _groupWords(visible) : null;
        final availableLetters = groupedWords == null
            ? const <String>[]
            : groupedWords.keys.where((key) => key != '#').toList();

        for (final letter in availableLetters) {
          _sectionKeys.putIfAbsent(letter, () => GlobalKey());
        }

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
                          onChanged: (value) =>
                              setState(() => query = value.trim()),
                          decoration: InputDecoration(
                            hintText: 'Search words or meanings',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    onPressed: () {
                                      _queryController.clear();
                                      setState(() => query = '');
                                    },
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
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '$unknownInChapter unknown/review  •  $knownInChapter known',
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
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: visible.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(28),
                              child: Text(
                                query.isNotEmpty
                                    ? 'No matching words.'
                                    : showKnown
                                        ? 'This chapter has no words.'
                                        : 'All words in this chapter are marked known.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.black54,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          )
                        : _isImageBook
                            ? ListView(
                                controller: _wordScrollController,
                                padding: const EdgeInsets.fromLTRB(16, 4, 42, 112),
                                children: [
                                  for (final group in groupedWords!.entries)
                                    Column(
                                      key: _sectionKeys[group.key],
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                              2, 12, 8, 8),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 32,
                                                height: 32,
                                                alignment: Alignment.center,
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFE4EFE8),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Text(
                                                  group.key,
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
                                                  color: const Color(0xFF356859)
                                                      .withOpacity(0.16),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        for (final entry in group.value)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 8),
                                            child: _wordCard(entry),
                                          ),
                                      ],
                                    ),
                                ],
                              )
                            : ListView.separated(
                                controller: _wordScrollController,
                                padding:
                                    const EdgeInsets.fromLTRB(16, 4, 16, 100),
                                itemCount: visible.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, index) =>
                                    _wordCard(visible[index]),
                              ),
                  ),
                ],
              ),
              if (_isImageBook && availableLetters.isNotEmpty)
                Positioned(
                  right: 1,
                  top: 145,
                  bottom: 92,
                  child: AlphabetFastScroller(
                    controller: _wordScrollController,
                    names: availableLetters,
                    itemExtent: 0,
                    onLetterSelected: _scrollToLetter,
                  ),
                ),
              Positioned(
                left: 16,
                bottom: 16,
                child: Container(
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
                      const Padding(
                        padding: EdgeInsets.only(left: 45),
                        child: Text(
                          'Slide to mark all →',
                          style: TextStyle(
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
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 22,
                          ),
                          overlayColor: Colors.transparent,
                        ),
                        child: Slider(
                          value: _sliderValue,
                          onChanged: (value) {
                            setState(() => _sliderValue = value);
                            if (value == 1.0) {
                              widget.store.markAllChapterKnown(currentChapter);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    '✨ All eligible words marked known (Show Again protected)!',
                                  ),
                                  backgroundColor: Color(0xFF27845B),
                                ),
                              );
                              Future.delayed(
                                const Duration(milliseconds: 300),
                                () {
                                  if (mounted) {
                                    setState(() => _sliderValue = 0.0);
                                  }
                                },
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
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
      },
    );
  }
}
