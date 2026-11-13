import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Future<void> _saveChain = Future.value();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadKnownWords();
    // Warm the offline dictionary in the background on first launch. A failed
    // download does not block the app; the Image Book screen offers retry.
    dictionary.load().catchError((_) {});

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
          final pages = (data['pages'] as List? ?? const []).map((e) {
            final page = e as Map<String, dynamic>;
            return ChapterData(
              title: (page['name'] ?? 'Page').toString(), pageRange: '',
              imagePath: page['imagePath']?.toString(),
              words: (page['words'] as List? ?? const []).map((w) => WordEntry.fromJson(Map<String, dynamic>.from(w))).toList(),
            );
          }).toList();
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
      for (final chapter in book.allChapters) {
        for (final entry in chapter.words) {
          all.add(normalizeWord(entry.word));
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
    final data = {'version': 1, 'name': book.name, 'pages': book.pages.map((p) => {'name': p.title, 'imagePath': p.imagePath, 'words': p.words.map((w) => w.toJson()).toList()}).toList()};
    final file = File(book.jsonPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);
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
    final imagePath = '${File(book.jsonPath).parent.path}/pages/page_${DateTime.now().microsecondsSinceEpoch}.jpg';
    await File(imagePath).writeAsBytes(jpg, flush: true);
    try {
      final words = await _ocr.extractWords(imagePath, dictionary);
      book.pages.add(ChapterData(title: 'Page-$number', pageRange: '', words: words, imagePath: imagePath));
      await _saveImageMetadata(book);
      _uniqueCache.remove(book.id);
      notifyListeners();
    } catch (_) {
      await File(imagePath).delete().catchError((_) => File(imagePath));
      rethrow;
    }
  }

  Future<void> renamePage(BookData book, ChapterData page, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Page name cannot be empty.');
    final index = book.pages.indexOf(page);
    if (index < 0) return;
    book.pages[index] = ChapterData(title: clean, pageRange: '', words: page.words, imagePath: page.imagePath);
    await _saveImageMetadata(book);
    notifyListeners();
  }

  Future<void> deletePage(BookData book, ChapterData page) async {
    book.pages.remove(page);
    if (page.imagePath != null) {
      final file = File(page.imagePath!);
      if (await file.exists()) await file.delete();
    }
    await _saveImageMetadata(book);
    _uniqueCache.remove(book.id);
    notifyListeners();
  }

  Future<void> removeBook(BookData book) async {
    books.removeWhere((b) => b.id == book.id);
    _uniqueCache.remove(book.id);
    if (book.isImageBook) {
      final folder = File(book.jsonPath).parent;
      if (await folder.exists()) await folder.delete(recursive: true);
    } else {
      final file = File(book.jsonPath);
      if (await file.exists()) await file.delete();
    }
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
              'type': b.isImageBook ? 'image' : 'json',
            }))
        .toList();
    await _prefs.setStringList('book_records', records);
  }
}

// ───────────────────────── JSON parser ─────────────────────────
