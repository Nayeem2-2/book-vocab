import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;

import '../models/book_models.dart';
import '../parsing/json_book_parser.dart';
import 'dictionary_service.dart';
import 'ocr_service.dart';

class BookStore extends ChangeNotifier {
  late SharedPreferences _prefs;
  final List<BookData> books = [];
  final DictionaryService dictionary = DictionaryService();
  final OcrService _ocr = OcrService();

  /// Global word states (shared by all books). Stored in known_words.json.
  final Set<String> _known = {};
  final Set<String> _showAgain = {};

  final Map<String, Set<String>> _uniqueCache = {};
  final Map<String, int> _knownCountCache = {};
  final Map<String, int> _showAgainCountCache = {};
  final Map<String, Future<void>> _bookWordCacheFutures = {};
  final Map<String, int> _bookWordCacheGenerations = {};

  // Word-state updates are intentionally separate from structural store
  // notifications. A single status tap must not rebuild Books/Pages/App bars.
  final ValueNotifier<int> wordStateRevision = ValueNotifier<int>(0);
  final Map<String, _WordStateSignal> _wordStateSignals = {};
  static const int _maxWordStateSignals = 512;
  final Map<String, _PracticeScopeCache> _practiceScopeCache = {};
  static const int _maxPracticeScopeCaches = 8;

  Future<void> _saveChain = Future.value();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadKnownWords();
    // Load the dictionary directly from the bundled application asset.
    // Loading happens asynchronously; JSON parsing runs in a background
    // isolate so it does not block scrolling or other UI work.
    dictionary.load().catchError((error) {
      debugPrint('Bundled dictionary could not be loaded: $error');
    });

    final directory = await _booksDirectory();
    final saved = _prefs.getStringList('book_records') ?? [];

    for (final record in saved) {
      try {
        final map = jsonDecode(record) as Map<String, dynamic>;
        final id = map['id'] as String;
        if (map['type'] == 'image') {
          final folder = Directory('${directory.path}/$id');
          final metadata = File('${folder.path}/book.json');
          if (!await metadata.exists()) continue;
          final data = jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
          final rawPages = data['pages'] as List? ?? const [];
          final pages = <ChapterData>[];
          for (var pageIndex = 0; pageIndex < rawPages.length; pageIndex++) {
            final page = Map<String, dynamic>.from(rawPages[pageIndex] as Map);
            final imagePath = page['imagePath']?.toString();
            pages.add(ChapterData(
              id: (page['id'] ?? imagePath ?? '${id}_$pageIndex').toString(),
              title: (page['name'] ?? 'Page').toString(),
              pageRange: '',
              imagePath: imagePath,
              words: (page['words'] as List? ?? const [])
                  .map((w) => WordEntry.fromJson(Map<String, dynamic>.from(w)))
                  .toList(),
            ));
          }
          books.add(BookData(id: id, name: (map['name'] ?? 'Untitled book').toString(), fileName: '', parts: const [], jsonPath: metadata.path, isImageBook: true, pages: pages));
        } else {
          final path = '${directory.path}/$id.json';
          final file = File(path);
          if (!await file.exists()) continue;
          final decoded = jsonDecode(await file.readAsString());
          final parts = JsonBookParser.parseParts(decoded);
          books.add(BookData(id: id, name: (map['name'] ?? 'Untitled book').toString(), fileName: (map['fileName'] ?? 'book.json').toString(), parts: parts, jsonPath: path));
        }
      } catch (_) {}
    }
  }

  // ── Known words file ──

  Future<File> _knownFile() async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/known_words.json');
  }

  Future<void> _loadKnownWords() async {
    final file = await _knownFile();
    if (await file.exists()) {
      try {
        _mergeJson(jsonDecode(await file.readAsString()));
        return;
      } catch (_) {
        _known.clear();
        _showAgain.clear();
      }
    }
    await _migrateFromPrefs();
  }

  /// One-time migration of the old per-book states into the global file.
  Future<void> _migrateFromPrefs() async {
    final saved = _prefs.getStringList('book_records') ?? [];
    for (final record in saved) {
      try {
        final map = jsonDecode(record) as Map<String, dynamic>;
        final id = map['id'] as String;
        final states = _prefs.getStringList('states_$id') ?? [];
        for (final entry in states) {
          final idx = entry.lastIndexOf(':');
          if (idx <= 0) continue;
          final w = normalizeWord(entry.substring(0, idx));
          final s = entry.substring(idx + 1);
          if (w.isEmpty) continue;
          if (s == 'known') {
            _known.add(w);
          } else if (s == 'showAgain') {
            _showAgain.add(w);
          }
        }
      } catch (_) {}
    }
    _showAgain.removeAll(_known);
    await _writeNow();
  }

  /// Merges a decoded known_words.json into memory. Known wins over showAgain.
  /// Returns how many words became newly known.
  int _mergeJson(dynamic decoded) {
    List<dynamic> knownList = const [];
    List<dynamic> againList = const [];

    if (decoded is List) {
      knownList = decoded;
    } else if (decoded is Map) {
      final k = decoded['known'];
      final a = decoded['showAgain'] ?? decoded['show_again'];
      if (k is! List && a is! List) {
        throw const FormatException(
            'This file has no "known" or "showAgain" list.');
      }
      if (k is List) knownList = k;
      if (a is List) againList = a;
    } else {
      throw const FormatException('Unrecognised known words file.');
    }

    final before = _known.length;
    for (final item in knownList) {
      final w = normalizeWord(item.toString());
      if (w.isEmpty) continue;
      _known.add(w);
      _showAgain.remove(w);
    }
    for (final item in againList) {
      final w = normalizeWord(item.toString());
      if (w.isEmpty || _known.contains(w)) continue;
      _showAgain.add(w);
    }
    return _known.length - before;
  }

  String _encode() {
    final known = _known.toList()..sort();
    final again = _showAgain.toList()..sort();
    return const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'known': known,
      'showAgain': again,
    });
  }

  Future<void> _writeNow() async {
    final file = await _knownFile();
    await file.writeAsString(_encode(), flush: true);
  }

  Future<void> _saveKnownWords() {
    _saveChain = _saveChain.then((_) => _writeNow()).catchError((_) {});
    return _saveChain;
  }

  /// Lets the user save known_words.json anywhere. Returns the path or null.
  Future<String?> exportKnownWords() async {
    final bytes = Uint8List.fromList(utf8.encode(_encode()));
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export known words',
      fileName: 'known_words.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: bytes,
    );
    if (path == null) return null;
    if (!(Platform.isAndroid || Platform.isIOS)) {
      await File(path).writeAsBytes(bytes);
    }
    return path;
  }

  /// Picks a known_words.json and merges it. Returns newly known count, or null if cancelled.
  Future<int?> importKnownWords() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      throw Exception('Could not read the selected file.');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    final added = _mergeJson(decoded);
    _refreshCachedWordCounts();
    wordStateRevision.value++;
    await _saveKnownWords();
    return added;
  }

  // ── Books ──

  Future<Directory> _booksDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/books');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  static String normalizeWord(String word) => word.trim().toLowerCase();

  WordState getWordState(String word) {
    final key = normalizeWord(word);
    if (_known.contains(key)) return WordState.known;
    if (_showAgain.contains(key)) return WordState.showAgain;
    return WordState.unknown;
  }

  ValueListenable<WordState> wordStateListenable(String word) {
    final key = normalizeWord(word);
    final existing = _wordStateSignals.remove(key);
    if (existing != null) {
      // Map insertion order is a small LRU. Reusing a recently detached signal
      // also avoids rebuilding it during a list child's dispose/update cycle.
      _wordStateSignals[key] = existing;
      return existing;
    }

    final signal = _WordStateSignal(
      getWordState(key),
      onNoListeners: _trimWordStateSignals,
    );
    _wordStateSignals[key] = signal;
    _trimWordStateSignals();
    return signal;
  }

  void _trimWordStateSignals() {
    while (_wordStateSignals.length > _maxWordStateSignals) {
      String? removableKey;
      for (final entry in _wordStateSignals.entries) {
        if (entry.value.listenerCount == 0) {
          removableKey = entry.key;
          break;
        }
      }
      if (removableKey == null) return;
      _wordStateSignals.remove(removableKey)?.dispose();
    }
  }

  Set<String> uniqueWords(BookData book) {
    final cached = _uniqueCache[book.id];
    if (cached != null) return cached;

    // Synchronous fallback for small, immediate operations such as starting a
    // game. Library widgets use ensureBookWordCache() so a large book is never
    // scanned as part of a scrolling frame.
    final all = <String>{};
    for (final chapter in book.allChapters) {
      for (final entry in chapter.words) {
        final key = normalizeWord(entry.word);
        if (key.isNotEmpty) all.add(key);
      }
    }
    _installBookWordCache(book, all);
    return all;
  }

  /// Builds the whole-book vocabulary index cooperatively. Work is split into
  /// small chunks so opening/scrolling library screens doesn't spend a long
  /// uninterrupted frame scanning every word in a multi-thousand-page book.
  /// Concurrent widgets share the same Future.
  Future<void> ensureBookWordCache(BookData book) {
    final existing = _bookWordCacheFutures[book.id];
    if (existing != null) return existing;
    if (_uniqueCache.containsKey(book.id)) {
      return _bookWordCacheFutures.putIfAbsent(
        book.id,
        () => Future<void>.value(),
      );
    }

    final generation = _bookWordCacheGenerations[book.id] ?? 0;
    late final Future<void> future;
    future = _buildBookWordCache(book, generation).catchError((Object error) {
      if (identical(_bookWordCacheFutures[book.id], future)) {
        _bookWordCacheFutures.remove(book.id);
      }
      throw error;
    });
    _bookWordCacheFutures[book.id] = future;
    return future;
  }

  Future<void> _buildBookWordCache(BookData book, int generation) async {
    final all = <String>{};
    var known = 0;
    var again = 0;
    var processed = 0;
    final stateRevisionAtStart = wordStateRevision.value;
    final chapters = book.allChapters;

    for (final chapter in chapters) {
      for (final entry in chapter.words) {
        final key = normalizeWord(entry.word);
        if (key.isNotEmpty && all.add(key)) {
          final state = getWordState(key);
          if (state == WordState.known) {
            known++;
          } else if (state == WordState.showAgain) {
            again++;
          }
        }
        processed++;
        if (processed % 600 == 0) {
          await Future<void>.delayed(Duration.zero);
          if ((_bookWordCacheGenerations[book.id] ?? 0) != generation ||
              !books.any((item) => item.id == book.id)) {
            return;
          }
        }
      }
    }

    if ((_bookWordCacheGenerations[book.id] ?? 0) != generation ||
        !books.any((item) => item.id == book.id)) {
      return;
    }

    // A user may mark words while the cache is being warmed. Recount against
    // the final state revision, yielding between chunks if the dataset is big.
    if (stateRevisionAtStart != wordStateRevision.value) {
      while (true) {
        final revision = wordStateRevision.value;
        known = 0;
        again = 0;
        var counted = 0;
        for (final key in all) {
          final state = getWordState(key);
          if (state == WordState.known) {
            known++;
          } else if (state == WordState.showAgain) {
            again++;
          }
          counted++;
          if (counted % 600 == 0) {
            await Future<void>.delayed(Duration.zero);
            if ((_bookWordCacheGenerations[book.id] ?? 0) != generation) {
              return;
            }
          }
        }
        if (revision == wordStateRevision.value) break;
      }
    }

    if ((_bookWordCacheGenerations[book.id] ?? 0) != generation) return;
    _installBookWordCache(book, all, known: known, showAgain: again);
  }

  void _installBookWordCache(
    BookData book,
    Set<String> all, {
    int? known,
    int? showAgain,
  }) {
    // Book-level membership is checked against the small set of cached books
    // when a state changes. This avoids retaining a second, high-overhead
    // word→book reverse index for hundreds of thousands of distinct words.
    _invalidateBookWordCache(book.id, bumpGeneration: false);
    _uniqueCache[book.id] = all;
    // Work with non-null local counters. The optional parameters remain
    // nullable by contract, so incrementing them directly is not valid under
    // Dart's null-safety rules.
    var knownCount = known ?? 0;
    var showAgainCount = showAgain ?? 0;
    if (known == null || showAgain == null) {
      knownCount = 0;
      showAgainCount = 0;
      for (final key in all) {
        final state = getWordState(key);
        if (state == WordState.known) {
          knownCount++;
        } else if (state == WordState.showAgain) {
          showAgainCount++;
        }
      }
    }
    _knownCountCache[book.id] = knownCount;
    _showAgainCountCache[book.id] = showAgainCount;
  }

  bool hasBookWordCache(BookData book) => _uniqueCache.containsKey(book.id);

  PracticeCounts? cachedPracticeCountsForBook(BookData book) {
    final words = _uniqueCache[book.id];
    if (words == null) return null;
    return PracticeCounts(
      words.length - (_knownCountCache[book.id] ?? 0) -
          (_showAgainCountCache[book.id] ?? 0),
      _showAgainCountCache[book.id] ?? 0,
    );
  }

  int totalUniqueWords(BookData book) => uniqueWords(book).length;

  int knownCount(BookData book) {
    uniqueWords(book);
    return _knownCountCache[book.id] ?? 0;
  }

  /// O(1) aggregate counts for a whole book. This avoids retaining a second
  /// giant word set in the page-scope LRU just to enable the book Play button.
  PracticeCounts practiceCountsForBook(BookData book) {
    final words = uniqueWords(book);
    final known = _knownCountCache[book.id] ?? 0;
    final again = _showAgainCountCache[book.id] ?? 0;
    return PracticeCounts(words.length - known - again, again);
  }

  String _practiceScopeKey(List<ChapterData> chapters) {
    if (chapters.length == 1) {
      return 'chapter:${identityHashCode(chapters.single)}';
    }
    // Multi-chapter callers pass the stable PartData.chapters list. Using its
    // identity avoids rebuilding a long key on every PlayButton update.
    return 'list:${identityHashCode(chapters)}:${chapters.length}';
  }

  _PracticeScopeCache _practiceScope(List<ChapterData> chapters) {
    final key = _practiceScopeKey(chapters);
    final cached = _practiceScopeCache.remove(key);
    if (cached != null) {
      // Map insertion order is used as a small LRU: most recently used goes last.
      _practiceScopeCache[key] = cached;
      return cached;
    }

    final words = <String>{};
    var unknown = 0;
    var again = 0;
    for (final chapter in chapters) {
      for (final entry in chapter.words) {
        final word = normalizeWord(entry.word);
        if (word.isEmpty || !words.add(word)) continue;
        if (_known.contains(word)) continue;
        if (_showAgain.contains(word)) {
          again++;
        } else {
          unknown++;
        }
      }
    }
    final scope = _PracticeScopeCache(words: words, unknown: unknown, showAgain: again);
    _practiceScopeCache[key] = scope;
    while (_practiceScopeCache.length > _maxPracticeScopeCaches) {
      _removePracticeScopeCache(_practiceScopeCache.keys.first);
    }
    return scope;
  }

  void _removePracticeScopeCache(String key) {
    _practiceScopeCache.remove(key);
  }

  void _refreshCachedWordCounts() {
    for (final entry in _knownCountCache.entries.toList()) {
      final words = _uniqueCache[entry.key];
      if (words != null) {
        _knownCountCache[entry.key] = words.where(_known.contains).length;
        _showAgainCountCache[entry.key] = words.where(_showAgain.contains).length;
      }
    }
    for (final signal in _wordStateSignals.entries) {
      final refreshed = getWordState(signal.key);
      if (signal.value.value != refreshed) signal.value.value = refreshed;
    }
    for (final scope in _practiceScopeCache.values) {
      var unknown = 0;
      var again = 0;
      for (final word in scope.words) {
        if (_known.contains(word)) continue;
        if (_showAgain.contains(word)) {
          again++;
        } else {
          unknown++;
        }
      }
      scope.unknown = unknown;
      scope.showAgain = again;
    }
  }

  void _invalidateBookWordCache(String bookId, {bool bumpGeneration = true}) {
    if (bumpGeneration) {
      _bookWordCacheGenerations[bookId] =
          (_bookWordCacheGenerations[bookId] ?? 0) + 1;
      _bookWordCacheFutures.remove(bookId);
    }
    _uniqueCache.remove(bookId);
    _knownCountCache.remove(bookId);
    _showAgainCountCache.remove(bookId);
  }

  void _clearPracticeScopeCaches() {
    _practiceScopeCache.clear();
  }

  bool _applyWordState(String key, WordState newState) {
    final oldState = getWordState(key);
    if (oldState == newState) return false;

    _known.remove(key);
    _showAgain.remove(key);
    if (newState == WordState.known) {
      _known.add(key);
    } else if (newState == WordState.showAgain) {
      _showAgain.add(key);
    }
    final signal = _wordStateSignals[key];
    if (signal != null && signal.value != newState) {
      signal.value = newState;
    }

    // The number of books is normally small. Checking their cached unique-word
    // sets avoids a second map/list allocation for every distinct word.
    for (final entry in _uniqueCache.entries) {
      if (!entry.value.contains(key)) continue;
      final bookId = entry.key;
      if ((oldState == WordState.known) != (newState == WordState.known)) {
        final current = _knownCountCache[bookId];
        if (current != null) {
          _knownCountCache[bookId] = current +
              (newState == WordState.known ? 1 : -1);
        }
      }
      if ((oldState == WordState.showAgain) !=
          (newState == WordState.showAgain)) {
        final current = _showAgainCountCache[bookId];
        if (current != null) {
          _showAgainCountCache[bookId] = current +
              (newState == WordState.showAgain ? 1 : -1);
        }
      }
    }

    // Update only cached practice scopes that contain this word.
    // The scope cache is deliberately bounded (16 entries), so checking each
    // cached word set avoids a large word→scope reverse index in memory.
    for (final scope in _practiceScopeCache.values) {
      if (!scope.words.contains(key)) continue;
      if (oldState == WordState.unknown) scope.unknown--;
      if (oldState == WordState.showAgain) scope.showAgain--;
      if (newState == WordState.unknown) scope.unknown++;
      if (newState == WordState.showAgain) scope.showAgain++;
    }
    return true;
  }

  /// Distinct words in the given chapters that are unknown / show again.
  /// Known words are never counted. Words are global, so a word that is
  /// known anywhere is known everywhere.
  PracticeCounts practiceCounts(List<ChapterData> chapters) {
    final scope = _practiceScope(chapters);
    return PracticeCounts(scope.unknown, scope.showAgain);
  }

  int uniqueWordCount(List<ChapterData> chapters) =>
      _practiceScope(chapters).words.length;

  /// Distinct words of the given chapters to play, filtered by what the
  /// user ticked. Known words are always excluded.
  List<WordEntry> practiceWords(
    List<ChapterData> chapters, {
    bool includeUnknown = true,
    bool includeShowAgain = true,
  }) {
    final byKey = <String, WordEntry>{};
    for (final chapter in chapters) {
      for (final entry in chapter.words) {
        final key = normalizeWord(entry.word);
        if (_known.contains(key)) continue;
        final isAgain = _showAgain.contains(key);
        if (isAgain && !includeShowAgain) continue;
        if (!isAgain && !includeUnknown) continue;
        final existing = byKey[key];
        if (existing == null) {
          byKey[key] = WordEntry(
            word: entry.word,
            meanings: List<String>.from(entry.meanings),
          );
        } else {
          for (final m in entry.meanings) {
            if (!existing.meanings.contains(m)) existing.meanings.add(m);
          }
        }
      }
    }
    return byKey.values.toList();
  }

  Future<void> setWordState(String word, WordState newState) async {
    final key = normalizeWord(word);
    if (key.isEmpty) return;
    if (!_applyWordState(key, newState)) return;
    wordStateRevision.value++;
    await _saveKnownWords();
  }

  Future<void> markAllChapterKnown(ChapterData chapter) async {
    var changed = false;
    var processed = 0;
    for (final entry in chapter.words) {
      final key = normalizeWord(entry.word);
      if (key.isEmpty || _showAgain.contains(key)) continue;
      changed = _applyWordState(key, WordState.known) || changed;
      processed++;
      // Yield periodically so a very large page never monopolizes a frame.
      if (processed % 1500 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (changed) {
      wordStateRevision.value++;
      await _saveKnownWords();
    }
  }

  Future<String?> importBook() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;

    final picked = result.files.single;
    final bytes = picked.bytes;
    if (bytes == null) {
      throw Exception('Could not read the selected file. Please select it again.');
    }

    final raw = utf8.decode(bytes);
    final decoded = jsonDecode(raw);
    final parts = JsonBookParser.parseParts(decoded);
    if (parts.isEmpty) {
      throw Exception(
        'No Parts/Chapters were found. Please check that this is a book vocabulary JSON.',
      );
    }

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final directory = await _booksDirectory();
    final path = '${directory.path}/$id.json';
    await File(path).writeAsString(raw);

    final name = JsonBookParser.bookName(decoded, picked.name);
    final book = BookData(
      id: id,
      name: name,
      fileName: picked.name,
      parts: parts,
      jsonPath: path,
    );
    books.add(book);
    await _saveBookRecords();
    notifyListeners();
    return id;
  }

  Future<BookData> createImageBook(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Please enter a book name.');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final root = await _booksDirectory();
    final folder = Directory('${root.path}/$id');
    await Directory('${folder.path}/pages').create(recursive: true);
    final book = BookData(id: id, name: clean, fileName: '', parts: const [], jsonPath: '${folder.path}/book.json', isImageBook: true, pages: []);
    books.add(book);
    await _saveImageMetadata(book);
    await _saveBookRecords();
    notifyListeners();
    return book;
  }

  Future<void> _saveImageMetadata(BookData book) async {
    final data = {
      'version': 1,
      'name': book.name,
      'pages': book.pages
          .map((page) => {
                'id': page.stableId,
                'name': page.title,
                'imagePath': page.imagePath,
                'words': page.words.map((word) => word.toJson()).toList(),
              })
          .toList(),
    };
    final file = File(book.jsonPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
  }

  Future<void> addScannedPage(BookData book, Uint8List bytes) async {
    if (!book.isImageBook) throw Exception('Pages can only be added to an image book.');
    if (!dictionary.isLoaded) await dictionary.load();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('This image format could not be opened.');
    final jpg = img.encodeJpg(decoded, quality: 90);
    var number = book.pages.length + 1;
    final existingNames = book.pages.map((p) => p.title).toSet();
    while (existingNames.contains('Page-$number')) { number++; }
    final pageId = DateTime.now().microsecondsSinceEpoch.toString();
    final imagePath = '${File(book.jsonPath).parent.path}/pages/page_$pageId.jpg';
    await File(imagePath).writeAsBytes(jpg, flush: true);
    try {
      final words = await _ocr.extractWords(imagePath, dictionary);
      book.pages.add(ChapterData(
        id: pageId,
        title: 'Page-$number',
        pageRange: '',
        words: words,
        imagePath: imagePath,
      ));
      await _saveImageMetadata(book);
      _invalidateBookWordCache(book.id);
      _clearPracticeScopeCaches();
      notifyListeners();
    } catch (_) {
      await File(imagePath).delete().catchError((_) => File(imagePath));
      rethrow;
    }
  }

  Future<void> renameBook(BookData book, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Book name cannot be empty.');
    BookData? current;
    for (final item in books) {
      if (item.id == book.id) {
        current = item;
        break;
      }
    }
    if (current == null) return;
    current.name = clean;
    if (current.isImageBook) await _saveImageMetadata(current);
    await _saveBookRecords();
    notifyListeners();
  }

  Future<void> renamePage(BookData book, ChapterData page, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Page name cannot be empty.');
    final index = book.pages.indexWhere(
      (candidate) => candidate.stableId == page.stableId,
    );
    if (index < 0) return;

    // Update the existing model instead of replacing it. Existing routes,
    // selection sets and widgets therefore keep referring to the same page.
    book.pages[index].title = clean;
    await _saveImageMetadata(book);
    // Renaming changes the alphabetical page index, not the vocabulary cache.
    notifyListeners();
  }

  Future<void> deletePage(BookData book, ChapterData page) async {
    await deletePages(book, [page]);
  }

  Future<void> deletePages(BookData book, Iterable<ChapterData> pagesToDelete) async {
    final targetIds = pagesToDelete.map((page) => page.stableId).toSet();
    if (targetIds.isEmpty) return;

    final removed = book.pages
        .where((page) => targetIds.contains(page.stableId))
        .toList();
    if (removed.isEmpty) return;

    book.pages.removeWhere((page) => targetIds.contains(page.stableId));
    for (final page in removed) {
      final imagePath = page.imagePath;
      if (imagePath == null || imagePath.isEmpty) continue;
      final file = File(imagePath);
      if (await file.exists()) await file.delete();
    }

    await _saveImageMetadata(book);
    _invalidateBookWordCache(book.id);
    _clearPracticeScopeCaches();
    notifyListeners();
  }

  Future<void> removeBook(BookData book) async {
    await removeBooks([book]);
  }

  Future<void> removeBooks(Iterable<BookData> booksToDelete) async {
    final targetIds = booksToDelete.map((book) => book.id).toSet();
    if (targetIds.isEmpty) return;

    final removed = books.where((book) => targetIds.contains(book.id)).toList();
    if (removed.isEmpty) return;

    books.removeWhere((book) => targetIds.contains(book.id));
    for (final book in removed) {
      _invalidateBookWordCache(book.id);
      _clearPracticeScopeCaches();
      if (book.isImageBook) {
        final folder = File(book.jsonPath).parent;
        if (await folder.exists()) await folder.delete(recursive: true);
      } else {
        final file = File(book.jsonPath);
        if (await file.exists()) await file.delete();
      }
      // Known words are intentionally global and are not deleted with a book.
      await _prefs.remove('states_${book.id}');
    }

    await _saveBookRecords();
    notifyListeners();
  }

  Future<void> _saveBookRecords() async {
    final records = books
        .map((b) => jsonEncode({
              'id': b.id,
              'name': b.name,
              'fileName': b.fileName,
              'type': b.isImageBook ? 'image' : 'json',
            }))
        .toList();
    await _prefs.setStringList('book_records', records);
  }
  @override
  void dispose() {
    wordStateRevision.dispose();
    for (final signal in _wordStateSignals.values.toList()) {
      signal.dispose();
    }
    _wordStateSignals.clear();
    super.dispose();
  }
}

class _WordStateSignal extends ValueNotifier<WordState> {
  _WordStateSignal(super.value, {required this.onNoListeners});

  final VoidCallback onNoListeners;
  int _listenerCount = 0;
  int get listenerCount => _listenerCount;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount++;
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_listenerCount > 0) {
      _listenerCount--;
      if (_listenerCount == 0) onNoListeners();
    }
  }
}

class _PracticeScopeCache {
  _PracticeScopeCache({
    required this.words,
    required this.unknown,
    required this.showAgain,
  });

  final Set<String> words;
  int unknown;
  int showAgain;
}

// ───────────────────────── JSON parser ─────────────────────────
