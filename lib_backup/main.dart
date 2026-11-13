import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = BookStore();
  await store.init();
  runApp(VocabularyApp(store: store));
}

class VocabularyApp extends StatelessWidget {
  const VocabularyApp({super.key, required this.store});
  final BookStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => MaterialApp(
        title: 'Book Vocabulary',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF356859),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF7F8F5),
          cardTheme: CardThemeData(
            elevation: 0,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: Color(0xFFE8ECE7)),
            ),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFF7F8F5),
            surfaceTintColor: Colors.transparent,
            centerTitle: false,
          ),
        ),
        home: BooksPage(store: store),
      ),
    );
  }
}

// ───────────────────────── Data models ─────────────────────────

class WordEntry {
  WordEntry({required this.word, required this.meanings});
  final String word;
  final List<String> meanings;
}

class ChapterData {
  ChapterData({
    required this.title,
    required this.pageRange,
    required this.words,
  });
  final String title;
  final String pageRange;
  final List<WordEntry> words;
}

class PartData {
  PartData({
    required this.title,
    required this.pageRange,
    required this.chapters,
  });
  final String title;
  final String pageRange;
  final List<ChapterData> chapters;
}

class BookData {
  BookData({
    required this.id,
    required this.name,
    required this.fileName,
    required this.parts,
    required this.jsonPath,
  });
  final String id;
  final String name;
  final String fileName;
  final List<PartData> parts;
  final String jsonPath;

  List<ChapterData> get allChapters =>
      [for (final p in parts) ...p.chapters];
}

enum WordState { unknown, known, showAgain }

/// How many distinct words in a scope are still to practise.
class PracticeCounts {
  const PracticeCounts(this.unknown, this.showAgain);
  final int unknown;
  final int showAgain;
  int get total => unknown + showAgain;
}

/// What the user ticked in the play options sheet.
class PlayChoice {
  const PlayChoice({required this.unknown, required this.showAgain});
  final bool unknown;
  final bool showAgain;
}

// ───────────────────────── Store ─────────────────────────

class BookStore extends ChangeNotifier {
  late SharedPreferences _prefs;
  final List<BookData> books = [];

  /// Global word states (shared by all books). Stored in known_words.json.
  final Set<String> _known = {};
  final Set<String> _showAgain = {};

  final Map<String, Set<String>> _uniqueCache = {};
  Future<void> _saveChain = Future.value();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadKnownWords();

    final directory = await _booksDirectory();
    final saved = _prefs.getStringList('book_records') ?? [];

    for (final record in saved) {
      try {
        final map = jsonDecode(record) as Map<String, dynamic>;
        final id = map['id'] as String;
        final path = '${directory.path}/$id.json';
        final file = File(path);
        if (!await file.exists()) continue;
        final raw = await file.readAsString();
        final decoded = jsonDecode(raw);
        final parts = JsonBookParser.parseParts(decoded);
        books.add(BookData(
          id: id,
          name: (map['name'] ?? 'Untitled book').toString(),
          fileName: (map['fileName'] ?? 'book.json').toString(),
          parts: parts,
          jsonPath: path,
        ));
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
    notifyListeners();
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

  Set<String> uniqueWords(BookData book) {
    return _uniqueCache.putIfAbsent(book.id, () {
      final all = <String>{};
      for (final part in book.parts) {
        for (final chapter in part.chapters) {
          for (final entry in chapter.words) {
            all.add(normalizeWord(entry.word));
          }
        }
      }
      return all;
    });
  }

  int totalUniqueWords(BookData book) => uniqueWords(book).length;

  int knownCount(BookData book) =>
      uniqueWords(book).where(_known.contains).length;

  /// Distinct words in the given chapters that are unknown / show again.
  /// Known words are never counted. Words are global, so a word that is
  /// known anywhere is known everywhere.
  PracticeCounts practiceCounts(List<ChapterData> chapters) {
    final seen = <String>{};
    var unknown = 0;
    var again = 0;
    for (final chapter in chapters) {
      for (final entry in chapter.words) {
        final key = normalizeWord(entry.word);
        if (!seen.add(key)) continue;
        if (_known.contains(key)) continue;
        if (_showAgain.contains(key)) {
          again++;
        } else {
          unknown++;
        }
      }
    }
    return PracticeCounts(unknown, again);
  }

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
    _known.remove(key);
    _showAgain.remove(key);
    if (newState == WordState.known) {
      _known.add(key);
    } else if (newState == WordState.showAgain) {
      _showAgain.add(key);
    }
    notifyListeners();
    await _saveKnownWords();
  }

  Future<void> markAllChapterKnown(ChapterData chapter) async {
    for (final entry in chapter.words) {
      final key = normalizeWord(entry.word);
      if (_showAgain.contains(key)) continue; // Show Again is protected
      _known.add(key);
    }
    notifyListeners();
    await _saveKnownWords();
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

  Future<void> removeBook(BookData book) async {
    books.removeWhere((b) => b.id == book.id);
    _uniqueCache.remove(book.id);
    final file = File(book.jsonPath);
    if (await file.exists()) await file.delete();
    await _prefs.remove('states_${book.id}');
    await _saveBookRecords();
    notifyListeners();
  }

  Future<void> _saveBookRecords() async {
    final records = books
        .map((b) => jsonEncode({
              'id': b.id,
              'name': b.name,
              'fileName': b.fileName,
            }))
        .toList();
    await _prefs.setStringList('book_records', records);
  }
}

// ───────────────────────── JSON parser ─────────────────────────

class JsonBookParser {
  static List<PartData> parseParts(dynamic root) {
    final rootMap = _asMap(root);
    if (rootMap == null) return [];

    dynamic rawParts = rootMap['parts'] ??
        rootMap['book_parts'] ??
        rootMap['structure'] ??
        rootMap['book_structure'];

    if (rawParts is Map &&
        rawParts.containsKey('parts') &&
        rawParts['parts'] is Map) {
      rawParts = rawParts['parts'];
    }

    final result = <PartData>[];

    if (rawParts is List) {
      for (var p = 0; p < rawParts.length; p++) {
        final partMap = _asMap(rawParts[p]);
        if (partMap == null) continue;

        final partTitle = _firstText(partMap, [
              'part_title',
              'part_name',
              'title',
              'name',
              'part'
            ]) ??
            'Part ${p + 1}';

        final chapters = _parseChapters(partMap);
        result.add(PartData(
          title: partTitle,
          pageRange: _pageRange(partMap),
          chapters: chapters,
        ));
      }
    } else if (rawParts is Map) {
      for (final entry in rawParts.entries) {
        final partMap = _asMap(entry.value);
        if (partMap == null) continue;

        final partTitle = entry.key.toString();
        final chapters = _parseChapters(partMap);
        result.add(PartData(
          title: partTitle,
          pageRange: _pageRange(partMap),
          chapters: chapters,
        ));
      }
    }
    return result;
  }

  static List<ChapterData> _parseChapters(Map<String, dynamic> partMap) {
    dynamic rawChapters =
        partMap['chapters'] ?? partMap['chapter_list'] ?? partMap['items'];

    if (rawChapters is Map &&
        rawChapters.containsKey('chapters') &&
        rawChapters['chapters'] is Map) {
      rawChapters = rawChapters['chapters'];
    }

    final chapters = <ChapterData>[];

    if (rawChapters is List) {
      for (var c = 0; c < rawChapters.length; c++) {
        final chapterMap = _asMap(rawChapters[c]);
        if (chapterMap == null) continue;

        final chapterTitle = _firstText(chapterMap, [
              'chapter_title',
              'chapter_name',
              'title',
              'name',
              'chapter'
            ]) ??
            'Chapter ${c + 1}';

        final words = _parseWords(chapterMap);
        chapters.add(ChapterData(
          title: chapterTitle,
          pageRange: _pageRange(chapterMap),
          words: words,
        ));
      }
    } else if (rawChapters is Map) {
      for (final entry in rawChapters.entries) {
        final chapterMap = _asMap(entry.value);
        if (chapterMap == null) continue;

        final chapterTitle = entry.key.toString();
        final words = _parseWords(chapterMap);
        chapters.add(ChapterData(
          title: chapterTitle,
          pageRange: _pageRange(chapterMap),
          words: words,
        ));
      }
    }
    return chapters;
  }

  static List<WordEntry> _parseWords(Map<String, dynamic> chapter) {
    final entries = <WordEntry>[];
    final seen = <String>{};

    void add(String word, dynamic meanings) {
      final cleanWord = word.trim();
      if (cleanWord.isEmpty) return;
      final key = BookStore.normalizeWord(cleanWord);
      if (!seen.add(key)) return;
      entries.add(WordEntry(
        word: cleanWord,
        meanings: _meaningList(meanings),
      ));
    }

    final rawEntries = chapter['word_entries'] ??
        chapter['words_with_meanings'] ??
        chapter['vocabulary'];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final word = _firstText(map, ['word', 'english', 'en', 'term']);
          if (word != null) {
            final meanings = map['bangla_meanings'] ??
                map['meanings'] ??
                map['bn'] ??
                map['meaning'];
            add(word, meanings);
          }
        } else if (item is String) {
          add(item, null);
        }
      }
    }

    final mapMeanings = chapter['bangla_meanings'] ??
        chapter['meanings_by_word'] ??
        chapter['word_meanings'];
    if (mapMeanings is Map) {
      for (final entry in mapMeanings.entries) {
        if (!seen.contains(BookStore.normalizeWord(entry.key.toString()))) {
          add(entry.key.toString(), entry.value);
        }
      }
    }

    if (entries.isEmpty) {
      final rawWords = chapter['distinct_words'] ?? chapter['words'];
      if (rawWords is List) {
        for (final item in rawWords) {
          if (item is String) {
            add(item, null);
          } else if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final word = _firstText(map, ['word', 'english', 'en', 'term']);
            if (word != null) {
              add(word, map['bangla_meanings'] ?? map['meanings'] ?? map['bn']);
            }
          }
        }
      } else if (rawWords is Map) {
        for (final entry in rawWords.entries) {
          add(entry.key.toString(), entry.value);
        }
      }
    }
    entries
        .sort((a, b) => a.word.toLowerCase().compareTo(b.word.toLowerCase()));
    return entries;
  }

  static List<String> _meaningList(dynamic value) {
    final values = <String>[];
    if (value is String) {
      if (value.trim().isNotEmpty) values.add(value.trim());
    } else if (value is List) {
      for (final item in value) {
        if (item != null && item.toString().trim().isNotEmpty) {
          final text = item.toString().trim();
          if (!values.contains(text)) values.add(text);
        }
      }
    } else if (value is Map) {
      for (final item in value.values) {
        values.addAll(_meaningList(item));
      }
    }
    return values;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static String? _firstText(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }
    return null;
  }

  static String _pageRange(Map<String, dynamic> map) {
    final direct = _firstText(map, ['page_range', 'pages']);
    if (direct != null && !direct.startsWith('{')) return direct;

    final rangeMap = _asMap(map['page_range']);
    if (rangeMap != null) {
      final start = rangeMap['start_page'] ?? rangeMap['page_start'];
      final end = rangeMap['end_page'] ?? rangeMap['page_end'];
      if (start != null && end != null) return 'Pages $start–$end';
      if (start != null) return 'Page $start';
    }

    final start = map['start_page'] ?? map['page_start'];
    final end = map['end_page'] ?? map['page_end'];
    if (start != null && end != null) return 'Pages $start–$end';
    if (start != null) return 'Page $start';
    return '';
  }

  static String bookName(dynamic root, String fallback) {
    final map = _asMap(root);
    if (map == null) return fallback.replaceAll('.json', '');

    final metadata = _asMap(map['metadata']);
    if (metadata != null) {
      final sourcePdf = _firstText(metadata, ['source_pdf']);
      if (sourcePdf != null) {
        return sourcePdf.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      }
    }

    return _firstText(map, ['book_title', 'book_name', 'title', 'name']) ??
        fallback.replaceAll(RegExp(r'\.json$', caseSensitive: false), '');
  }
}

// ───────────────────────── Play button + options ─────────────────────────

/// Opens the play options sheet for a scope (book / part / chapter) and,
/// if confirmed, starts the game with only the ticked kinds of words.
Future<void> startGame(
  BuildContext context,
  BookStore store,
  String title,
  List<ChapterData> chapters,
) async {
  final counts = store.practiceCounts(chapters);
  if (counts.total == 0) return;

  final choice = await showModalBottomSheet<PlayChoice>(
    context: context,
    showDragHandle: true,
    backgroundColor: Colors.white,
    builder: (_) => _PlayOptionsSheet(title: title, counts: counts),
  );
  if (choice == null || !context.mounted) return;

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => GamePage(
        store: store,
        title: title,
        chapters: chapters,
        includeUnknown: choice.unknown,
        includeShowAgain: choice.showAgain,
      ),
    ),
  );
}

class _PlayOptionsSheet extends StatefulWidget {
  const _PlayOptionsSheet({required this.title, required this.counts});
  final String title;
  final PracticeCounts counts;

  @override
  State<_PlayOptionsSheet> createState() => _PlayOptionsSheetState();
}

class _PlayOptionsSheetState extends State<_PlayOptionsSheet> {
  late bool _unknown = widget.counts.unknown > 0;
  late bool _again = widget.counts.showAgain > 0;

  int get _selected =>
      (_unknown ? widget.counts.unknown : 0) +
      (_again ? widget.counts.showAgain : 0);

  @override
  Widget build(BuildContext context) {
    final c = widget.counts;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Choose which words to play',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _unknown,
              onChanged: c.unknown > 0
                  ? (v) => setState(() => _unknown = v ?? false)
                  : null,
              title: const Text('Unknown',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${c.unknown} words not marked yet'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _again,
              onChanged: c.showAgain > 0
                  ? (v) => setState(() => _again = v ?? false)
                  : null,
              title: const Text('Show again',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${c.showAgain} words flagged to review'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _selected == 0
                    ? null
                    : () => Navigator.pop(
                          context,
                          PlayChoice(unknown: _unknown, showAgain: _again),
                        ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(
                  _selected == 0
                      ? 'Tick at least one option'
                      : 'Start  •  $_selected words',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Play icon used on books, parts and chapters. Faded and disabled when the
/// scope has no unknown / show again words left.
class PlayButton extends StatelessWidget {
  const PlayButton({
    super.key,
    required this.store,
    required this.title,
    required this.chapters,
    this.size = 32,
  });
  final BookStore store;
  final String title;
  final List<ChapterData> chapters;
  final double size;

  static const _green = Color(0xFF356859);

  @override
  Widget build(BuildContext context) {
    final counts = store.practiceCounts(chapters);
    final enabled = counts.total > 0;
    return IconButton(
      tooltip: enabled
          ? 'Play • ${counts.total} words to practise'
          : 'Nothing to practise',
      icon: Icon(
        Icons.play_circle_fill_rounded,
        size: size,
        color: enabled ? _green : _green.withOpacity(0.25),
      ),
      onPressed:
          enabled ? () => startGame(context, store, title, chapters) : null,
    );
  }
}

// ───────────────────────── Books page ─────────────────────────

class BooksPage extends StatelessWidget {
  const BooksPage({super.key, required this.store});
  final BookStore store;

  void _msg(BuildContext context, String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addBook(BuildContext context) async {
    try {
      await store.importBook();
    } catch (e) {
      _msg(context, 'Could not import book: $e');
    }
  }

  Future<void> _exportKnown(BuildContext context) async {
    try {
      final path = await store.exportKnownWords();
      if (path != null) _msg(context, 'Known words exported');
    } catch (e) {
      _msg(context, 'Export failed: $e');
    }
  }

  Future<void> _importKnown(BuildContext context) async {
    try {
      final added = await store.importKnownWords();
      if (added != null) {
        _msg(context, 'Imported and merged • $added new known words');
      }
    } catch (e) {
      _msg(context, 'Import failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Books',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Import a JSON book',
            onPressed: () => _addBook(context),
            icon: const Icon(Icons.add_circle_outline, size: 28),
          ),
          PopupMenuButton<String>(
            tooltip: 'Known words',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'export') _exportKnown(context);
              if (value == 'import') _importKnown(context);
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addBook(context),
        icon: const Icon(Icons.add),
        label: const Text('Add book'),
      ),
      body: store.books.isEmpty
          ? _EmptyState(onAdd: () => _addBook(context))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [
                const Text(
                  'Your vocabulary library',
                  style: TextStyle(fontSize: 14, color: Colors.black54),
                ),
                const SizedBox(height: 14),
                for (final book in store.books)
                  Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                      leading: Container(
                        width: 52,
                        height: 58,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F1EC),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.menu_book_rounded,
                            color: Color(0xFF356859), size: 30),
                      ),
                      title: Text(book.name,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${book.parts.length} Parts  •  ${store.totalUniqueWords(book)} unique words\n${store.knownCount(book)} known',
                        ),
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PlayButton(
                            store: store,
                            title: book.name,
                            chapters: book.allChapters,
                            size: 34,
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                PartsPage(store: store, book: book)),
                      ),
                    ),
                  ),
              ],
            ),
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
              const Icon(Icons.library_books_outlined,
                  size: 76, color: Color(0xFF8AA99A)),
              const SizedBox(height: 18),
              const Text('Your library is empty',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text(
                'Import a book JSON file. Each JSON will be stored as a separate book.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, height: 1.4),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import JSON')),
            ],
          ),
        ),
      );
}

// ───────────────────────── Parts / Chapters ─────────────────────────

class PartsPage extends StatelessWidget {
  const PartsPage({super.key, required this.store, required this.book});
  final BookStore store;
  final BookData book;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: store,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
              title: Text(book.name,
                  style: const TextStyle(fontWeight: FontWeight.w800))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _BookProgress(store: store, book: book),
              const SizedBox(height: 14),
              for (var i = 0; i < book.parts.length; i++)
                _FolderTile(
                  title: book.parts[i].title,
                  subtitle: [
                    '${book.parts[i].chapters.length} Chapters',
                    if (book.parts[i].pageRange.isNotEmpty)
                      book.parts[i].pageRange,
                  ].join('  •  '),
                  icon: Icons.folder_rounded,
                  play: PlayButton(
                    store: store,
                    title: book.parts[i].title,
                    chapters: book.parts[i].chapters,
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChaptersPage(
                          store: store, book: book, part: book.parts[i]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

class ChaptersPage extends StatelessWidget {
  const ChaptersPage(
      {super.key,
      required this.store,
      required this.book,
      required this.part});
  final BookStore store;
  final BookData book;
  final PartData part;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: store,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
              title: Text(part.title,
                  style: const TextStyle(fontWeight: FontWeight.w800))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (part.pageRange.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(part.pageRange,
                      style: const TextStyle(color: Colors.black54)),
                ),
              for (final chapter in part.chapters)
                _FolderTile(
                  title: chapter.title,
                  subtitle: [
                    '${chapter.words.length} words',
                    if (chapter.pageRange.isNotEmpty) chapter.pageRange,
                  ].join('  •  '),
                  icon: Icons.folder_open_rounded,
                  play: PlayButton(
                    store: store,
                    title: chapter.title,
                    chapters: [chapter],
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChapterPage(
                          store: store, book: book, chapter: chapter),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

class _FolderTile extends StatelessWidget {
  const _FolderTile(
      {required this.title,
      required this.subtitle,
      required this.icon,
      required this.onTap,
      this.play});
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? play;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          leading: Icon(icon, color: const Color(0xFFC18A35), size: 32),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(subtitle, style: const TextStyle(color: Colors.black54)),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (play != null) play!,
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: onTap,
        ),
      );
}

// ───────────────────────── Chapter page ─────────────────────────

class ChapterPage extends StatefulWidget {
  const ChapterPage(
      {super.key,
      required this.store,
      required this.book,
      required this.chapter});
  final BookStore store;
  final BookData book;
  final ChapterData chapter;

  @override
  State<ChapterPage> createState() => _ChapterPageState();
}

class _ChapterPageState extends State<ChapterPage> {
  bool showKnown = false;
  String query = '';
  double _sliderValue = 0.0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final visible = widget.chapter.words.where((entry) {
          final state = widget.store.getWordState(entry.word);
          final known = state == WordState.known;
          final matchesStatus = showKnown || !known;
          final matchesQuery = query.isEmpty ||
              entry.word.toLowerCase().contains(query.toLowerCase()) ||
              entry.meanings
                  .any((m) => m.toLowerCase().contains(query.toLowerCase()));
          return matchesStatus && matchesQuery;
        }).toList();

        final knownInChapter = widget.chapter.words
            .where((w) => widget.store.getWordState(w.word) == WordState.known)
            .length;
        final unknownInChapter = widget.chapter.words.length - knownInChapter;

        return Scaffold(
          appBar: AppBar(
            title: Text(widget.chapter.title,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              PlayButton(
                store: widget.store,
                title: widget.chapter.title,
                chapters: [widget.chapter],
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
                          onChanged: (value) =>
                              setState(() => query = value.trim()),
                          decoration: InputDecoration(
                            hintText: 'Search words or meanings',
                            prefixIcon: const Icon(Icons.search),
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
                                    color: Colors.black54, fontSize: 13),
                              ),
                            ),
                            const Text('Show known',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 13)),
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
                                    color: Colors.black54, fontSize: 16),
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                            itemCount: visible.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final entry = visible[index];
                              final state =
                                  widget.store.getWordState(entry.word);

                              Color badgeColor;
                              String badgeText;

                              if (state == WordState.known) {
                                badgeColor = const Color(0xFF27845B);
                                badgeText = 'KNOWN';
                              } else if (state == WordState.showAgain) {
                                badgeColor = const Color(0xFFD97706);
                                badgeText = 'SHOW AGAIN';
                              } else {
                                badgeColor = Colors.transparent;
                                badgeText = '';
                              }

                              return Dismissible(
                                key: Key(entry.word),
                                direction: state == WordState.known
                                    ? DismissDirection.startToEnd
                                    : DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(left: 20),
                                  color: Colors.orange.withOpacity(0.2),
                                  child: const Icon(Icons.replay,
                                      color: Color(0xFFD97706)),
                                ),
                                secondaryBackground: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF27845B)
                                        .withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: const Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Text('Known',
                                          style: TextStyle(
                                              color: Color(0xFF27845B),
                                              fontWeight: FontWeight.bold)),
                                      SizedBox(width: 8),
                                      Icon(Icons.check_circle,
                                          color: Color(0xFF27845B)),
                                    ],
                                  ),
                                ),
                                confirmDismiss: (direction) async {
                                  if (state == WordState.known &&
                                      direction == DismissDirection.startToEnd) {
                                    widget.store.setWordState(
                                        entry.word, WordState.showAgain);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('Moved to Show Again'),
                                          duration:
                                              Duration(milliseconds: 600)),
                                    );
                                  } else if (state != WordState.known &&
                                      direction == DismissDirection.endToStart) {
                                    widget.store.setWordState(
                                        entry.word, WordState.known);
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
                                  return false;
                                },
                                child: Card(
                                  child: Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(16, 13, 8, 13),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                entry.word,
                                                style: const TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.w800),
                                              ),
                                              const SizedBox(height: 5),
                                              Text(
                                                entry.meanings.isEmpty
                                                    ? 'বাংলা অর্থ পাওয়া যায়নি'
                                                    : entry.meanings
                                                        .join('  •  '),
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  height: 1.45,
                                                  color: entry.meanings.isEmpty
                                                      ? Colors.black38
                                                      : const Color(0xFF426B59),
                                                ),
                                              ),
                                              if (badgeText.isNotEmpty &&
                                                  (showKnown ||
                                                      state ==
                                                          WordState.showAgain))
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          top: 5),
                                                  child: Text(
                                                    badgeText,
                                                    style: TextStyle(
                                                      color: badgeColor,
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      letterSpacing: 1,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: state == WordState.known
                                              ? 'Mark unknown'
                                              : 'Mark known',
                                          onPressed: () {
                                            final next = state == WordState.known
                                                ? WordState.unknown
                                                : WordState.known;
                                            widget.store
                                                .setWordState(entry.word, next);
                                            if (next == WordState.known) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                const SnackBar(
                                                  content: Row(
                                                    children: [
                                                      Icon(Icons.auto_awesome,
                                                          color: Colors.amber,
                                                          size: 18),
                                                      SizedBox(width: 8),
                                                      Text('✨ Marked as Known!'),
                                                    ],
                                                  ),
                                                  duration:
                                                      Duration(milliseconds: 800),
                                                  backgroundColor:
                                                      Color(0xFF27845B),
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
                                            widget.store.setWordState(
                                                entry.word, WordState.showAgain);
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content:
                                                    Text('Flagged for Show Again'),
                                                duration:
                                                    Duration(milliseconds: 600),
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
                            },
                          ),
                  ),
                ],
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
                        color: const Color(0xFF356859).withOpacity(0.3)),
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
                              enabledThumbRadius: 22),
                          overlayColor: Colors.transparent,
                        ),
                        child: Slider(
                          value: _sliderValue,
                          onChanged: (val) {
                            setState(() => _sliderValue = val);
                            if (val == 1.0) {
                              widget.store.markAllChapterKnown(widget.chapter);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      '✨ All eligible words marked known (Show Again protected)!'),
                                  backgroundColor: Color(0xFF27845B),
                                ),
                              );
                              Future.delayed(const Duration(milliseconds: 300),
                                  () {
                                if (mounted) setState(() => _sliderValue = 0.0);
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BookProgress extends StatelessWidget {
  const _BookProgress({required this.store, required this.book});
  final BookStore store;
  final BookData book;

  @override
  Widget build(BuildContext context) {
    final total = store.totalUniqueWords(book);
    final known = store.knownCount(book);
    final progress =
        total == 0 ? 0.0 : (known / total).clamp(0.0, 1.0).toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Book progress',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                Text('$known / $total known',
                    style: const TextStyle(color: Colors.black54, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: LinearProgressIndicator(value: progress, minHeight: 8),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Bubble game ─────────────────────────

class GamePage extends StatefulWidget {
  const GamePage({
    super.key,
    required this.store,
    required this.title,
    required this.chapters,
    this.includeUnknown = true,
    this.includeShowAgain = true,
  });
  final BookStore store;
  final String title;
  final List<ChapterData> chapters;
  final bool includeUnknown;
  final bool includeShowAgain;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with TickerProviderStateMixin {
  static const _green = Color(0xFF27845B);
  static const _red = Color(0xFFC0392B);
  static const _ink = Color(0xFF1F3D33);

  late final AnimationController _enter;
  late final AnimationController _exit;
  late final AnimationController _idle;

  late List<WordEntry> _queue;
  int _total = 0;
  int _knownCount = 0;
  int _skips = 0;
  bool _busy = false;
  bool _exitKnown = true;

  /// Meaning stays hidden until "Show meaning" is pressed; resets per word.
  bool _showMeaning = false;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 380));
    _exit = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _idle = AnimationController(vsync: this, duration: const Duration(seconds: 4))
      ..repeat();

    _queue = widget.store.practiceWords(
      widget.chapters,
      includeUnknown: widget.includeUnknown,
      includeShowAgain: widget.includeShowAgain,
    )..shuffle();
    _total = _queue.length;
    if (_queue.isNotEmpty) _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    _exit.dispose();
    _idle.dispose();
    super.dispose();
  }

  Future<void> _answer(bool known) async {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    _exitKnown = known;
    HapticFeedback.lightImpact();
    await _exit.forward(from: 0);
    if (!mounted) return;

    final entry = _queue.removeAt(0);
    if (known) {
      _knownCount++;
      // Global: the word becomes known in every book, part and chapter.
      widget.store.setWordState(entry.word, WordState.known);
    } else {
      // Unknown: clear showAgain globally and send the bubble to the end.
      widget.store.setWordState(entry.word, WordState.unknown);
      _queue.add(entry);
      _skips++;
    }

    _enter.value = 0;
    _exit.value = 0;
    _showMeaning = false;
    setState(() {});
    _busy = false;
    if (_queue.isNotEmpty) _enter.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title,
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _queue.isEmpty ? _finished(context) : _playing(),
    );
  }

  Widget _finished(BuildContext context) {
    final nothing = _total == 0;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🎉', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 14),
            Text(
              nothing ? 'Nothing to practise' : 'Round complete!',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              nothing
                  ? 'No words match the options you picked.'
                  : '$_knownCount words marked known'
                      '${_skips > 0 ? '  •  $_skips skipped' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54, fontSize: 16),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playing() {
    final progress = _total == 0 ? 0.0 : _knownCount / _total;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('$_knownCount known  •  ${_queue.length} left',
                      style: const TextStyle(
                          color: Colors.black54, fontWeight: FontWeight.w600)),
                  Text('Skipped $_skips',
                      style: const TextStyle(color: Colors.black45)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(value: progress, minHeight: 8),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final h = c.maxHeight;
              final d = math.min(math.min(w * 0.88, h * 0.86), 360.0);
              const previewAlign = [
                Alignment(-0.82, -0.85),
                Alignment(0.85, -0.6),
                Alignment(-0.7, 0.85),
              ];
              const previewSize = [0.26, 0.19, 0.22];
              final previewCount = math.min(_queue.length - 1, 3);

              return AnimatedBuilder(
                animation: Listenable.merge([_enter, _exit, _idle]),
                builder: (context, _) {
                  if (_queue.isEmpty) return const SizedBox.shrink();
                  final phase = _idle.value * 2 * math.pi;
                  final enterT = Curves.easeOutCubic.transform(_enter.value);

                  double dx = math.sin(phase) * 6;
                  double dy = math.cos(phase) * 8 + (1 - enterT) * h * 0.8;
                  double scale = 1;
                  double opacity = math.min(1.0, _enter.value * 3);

                  if (_exit.value > 0) {
                    final t = Curves.easeIn.transform(_exit.value);
                    if (_exitKnown) {
                      // Pop
                      scale = 1 + 0.35 * t;
                      opacity *= (1 - t);
                      dy -= h * 0.04 * t;
                    } else {
                      // Fly off toward the Unknown button (bottom-left)
                      dx -= w * 0.45 * t;
                      dy += h * 0.3 * t;
                      scale = 1 - 0.6 * t;
                      opacity *= (1 - t);
                    }
                  }

                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      for (var i = 0; i < previewCount; i++)
                        Align(
                          alignment: previewAlign[i],
                          child: Transform.translate(
                            offset: Offset(math.sin(phase + i * 2) * 5,
                                math.cos(phase + i * 2) * 7),
                            child: Container(
                              width: d * previewSize[i],
                              height: d * previewSize[i],
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF356859).withOpacity(0.08),
                                border: Border.all(
                                  color:
                                      const Color(0xFF356859).withOpacity(0.18),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Center(
                        child: Transform.translate(
                          offset: Offset(dx, dy),
                          child: Transform.scale(
                            scale: scale,
                            child: Opacity(
                              opacity: opacity.clamp(0.0, 1.0),
                              child: _bubble(_queue.first, d),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF356859),
                      side: BorderSide(
                          color: const Color(0xFF356859).withOpacity(0.5)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () =>
                        setState(() => _showMeaning = !_showMeaning),
                    icon: Icon(_showMeaning
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    label: Text(
                      _showMeaning ? 'Hide meaning' : 'Show meaning',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: _red,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                          ),
                          onPressed: () => _answer(false),
                          icon: const Icon(Icons.close_rounded, size: 28),
                          label: const Text('Unknown',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: _green,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                          ),
                          onPressed: () => _answer(true),
                          icon: const Icon(Icons.check_rounded, size: 28),
                          label: const Text('Known',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _bubble(WordEntry entry, double d) {
    final state = widget.store.getWordState(entry.word);
    final meaning = entry.meanings.isEmpty
        ? 'বাংলা অর্থ পাওয়া যায়নি'
        : entry.meanings.join('  •  ');

    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          center: Alignment(-0.35, -0.4),
          radius: 0.95,
          colors: [Colors.white, Color(0xFFE3F1EA), Color(0xFFBFDCCE)],
          stops: [0.0, 0.65, 1.0],
        ),
        border: Border.all(
            color: const Color(0xFF356859).withOpacity(0.35), width: 2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF356859).withOpacity(0.22),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: SizedBox(
        width: d * 0.72,
        height: d * 0.6,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: d * 0.72,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state == WordState.showAgain)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Text(
                      'SHOW AGAIN',
                      style: TextStyle(
                        color: Color(0xFFD97706),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                Text(
                  entry.word,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: _ink,
                  ),
                ),
                if (_showMeaning) ...[
                  const SizedBox(height: 12),
                  Text(
                    meaning,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      height: 1.4,
                      color: entry.meanings.isEmpty
                          ? Colors.black38
                          : const Color(0xFF426B59),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}