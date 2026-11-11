import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
}

enum WordState { unknown, known, showAgain }

class BookStore extends ChangeNotifier {
  late SharedPreferences _prefs;
  final List<BookData> books = [];
  
  final Map<String, Map<String, WordState>> _wordStates = {};

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
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
        
        final stateMap = <String, WordState>{};
        final storedStates = _prefs.getStringList('states_$id') ?? [];
        for (final entryStr in storedStates) {
          final partsList = entryStr.split(':');
          if (partsList.length == 2) {
            final w = partsList[0];
            final stateName = partsList[1];
            if (stateName == 'known') {
              stateMap[w] = WordState.known;
            } else if (stateName == 'showAgain') {
              stateMap[w] = WordState.showAgain;
            }
          }
        }
        _wordStates[id] = stateMap;
      } catch (_) {}
    }
  }

  Future<Directory> _booksDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/books');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  static String normalizeWord(String word) => word.trim().toLowerCase();

  WordState getWordState(String bookId, String word) {
    return _wordStates[bookId]?[normalizeWord(word)] ?? WordState.unknown;
  }

  int knownCount(String bookId) {
    final map = _wordStates[bookId];
    if (map == null) return 0;
    return map.values.where((s) => s == WordState.known).length;
  }

  int totalUniqueWords(BookData book) {
    final all = <String>{};
    for (final part in book.parts) {
      for (final chapter in part.chapters) {
        for (final entry in chapter.words) {
          all.add(normalizeWord(entry.word));
        }
      }
    }
    return all.length;
  }

  Future<void> setWordState(String bookId, String word, WordState newState) async {
    final map = _wordStates.putIfAbsent(bookId, () => <String, WordState>{});
    final key = normalizeWord(word);
    
    if (newState == WordState.unknown) {
      map.remove(key);
    } else {
      map[key] = newState;
    }
    await _saveStates(bookId);
    notifyListeners();
  }

  Future<void> markAllChapterKnown(String bookId, ChapterData chapter) async {
    final map = _wordStates.putIfAbsent(bookId, () => <String, WordState>{});
    for (final entry in chapter.words) {
      final key = normalizeWord(entry.word);
      final currentState = map[key] ?? WordState.unknown;
      
      if (currentState != WordState.showAgain) {
        map[key] = WordState.known;
      }
    }
    await _saveStates(bookId);
    notifyListeners();
  }

  Future<void> _saveStates(String bookId) async {
    final map = _wordStates[bookId] ?? {};
    final list = <String>[];
    map.forEach((w, state) {
      if (state == WordState.known) {
        list.add('$w:known');
      } else if (state == WordState.showAgain) {
        list.add('$w:showAgain');
      }
    });
    await _prefs.setStringList('states_$bookId', list);
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
    _wordStates[id] = <String, WordState>{};
    await _prefs.setStringList('states_$id', []);
    await _saveBookRecords();
    notifyListeners();
    return id;
  }

  Future<void> removeBook(BookData book) async {
    books.removeWhere((b) => b.id == book.id);
    _wordStates.remove(book.id);
    final file = File(book.jsonPath);
    if (await file.exists()) await file.delete();
    await _prefs.remove('states_${book.id}');
    await _saveBookRecords();
    notifyListeners();
  }

  Future<void> _saveBookRecords() async {
    final records = books.map((b) => jsonEncode({
      'id': b.id,
      'name': b.name,
      'fileName': b.fileName,
    })).toList();
    await _prefs.setStringList('book_records', records);
  }
}

class JsonBookParser {
  static List<PartData> parseParts(dynamic root) {
    final rootMap = _asMap(root);
    if (rootMap == null) return [];

    dynamic rawParts = rootMap['parts'] ??
        rootMap['book_parts'] ??
        rootMap['structure'] ??
        rootMap['book_structure'];

    if (rawParts is Map && rawParts.containsKey('parts') && rawParts['parts'] is Map) {
      rawParts = rawParts['parts'];
    }

    final result = <PartData>[];

    if (rawParts is List) {
      for (var p = 0; p < rawParts.length; p++) {
        final partMap = _asMap(rawParts[p]);
        if (partMap == null) continue;

        final partTitle = _firstText(partMap, [
          'part_title', 'part_name', 'title', 'name', 'part'
        ]) ?? 'Part ${p + 1}';

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
    dynamic rawChapters = partMap['chapters'] ??
        partMap['chapter_list'] ??
        partMap['items'];

    if (rawChapters is Map && rawChapters.containsKey('chapters') && rawChapters['chapters'] is Map) {
      rawChapters = rawChapters['chapters'];
    }

    final chapters = <ChapterData>[];

    if (rawChapters is List) {
      for (var c = 0; c < rawChapters.length; c++) {
        final chapterMap = _asMap(rawChapters[c]);
        if (chapterMap == null) continue;

        final chapterTitle = _firstText(chapterMap, [
          'chapter_title', 'chapter_name', 'title', 'name', 'chapter'
        ]) ?? 'Chapter ${c + 1}';

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
                map['meanings'] ?? map['bn'] ?? map['meaning'];
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
    entries.sort((a, b) => a.word.toLowerCase().compareTo(b.word.toLowerCase()));
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

class BooksPage extends StatelessWidget {
  const BooksPage({super.key, required this.store});
  final BookStore store;

  Future<void> _addBook(BuildContext context) async {
    try {
      await store.importBook();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not import book: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Books', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Import a JSON book',
            onPressed: () => _addBook(context),
            icon: const Icon(Icons.add_circle_outline, size: 28),
          ),
          const SizedBox(width: 8),
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
                      contentPadding: const EdgeInsets.all(16),
                      leading: Container(
                        width: 52,
                        height: 58,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F1EC),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.menu_book_rounded, color: Color(0xFF356859), size: 30),
                      ),
                      title: Text(book.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${book.parts.length} Parts  •  ${store.totalUniqueWords(book)} unique words\n${store.knownCount(book.id)} known',
                        ),
                      ),
                      isThreeLine: true,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => PartsPage(store: store, book: book)),
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
          const Icon(Icons.library_books_outlined, size: 76, color: Color(0xFF8AA99A)),
          const SizedBox(height: 18),
          const Text('Your library is empty', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text(
            'Import a book JSON file. Each JSON will be stored as a separate book.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54, height: 1.4),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.upload_file), label: const Text('Import JSON')),
        ],
      ),
    ),
  );
}

class PartsPage extends StatelessWidget {
  const PartsPage({super.key, required this.store, required this.book});
  final BookStore store;
  final BookData book;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(book.name, style: const TextStyle(fontWeight: FontWeight.w800))),
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
              if (book.parts[i].pageRange.isNotEmpty) book.parts[i].pageRange,
            ].join('  •  '),
            icon: Icons.folder_rounded,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChaptersPage(store: store, book: book, part: book.parts[i]),
              ),
            ),
          ),
      ],
    ),
  );
}

class ChaptersPage extends StatelessWidget {
  const ChaptersPage({super.key, required this.store, required this.book, required this.part});
  final BookStore store;
  final BookData book;
  final PartData part;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(part.title, style: const TextStyle(fontWeight: FontWeight.w800))),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (part.pageRange.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(part.pageRange, style: const TextStyle(color: Colors.black54)),
          ),
        for (final chapter in part.chapters)
          _FolderTile(
            title: chapter.title,
            subtitle: [
              '${chapter.words.length} words',
              if (chapter.pageRange.isNotEmpty) chapter.pageRange,
            ].join('  •  '),
            icon: Icons.folder_open_rounded,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChapterPage(store: store, book: book, chapter: chapter),
              ),
            ),
          ),
      ],
    ),
  );
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.title, required this.subtitle, required this.icon, required this.onTap});
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      leading: Icon(icon, color: const Color(0xFFC18A35), size: 32),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Text(subtitle, style: const TextStyle(color: Colors.black54)),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

class ChapterPage extends StatefulWidget {
  const ChapterPage({super.key, required this.store, required this.book, required this.chapter});
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
          final state = widget.store.getWordState(widget.book.id, entry.word);
          final known = state == WordState.known;
          final matchesStatus = showKnown || !known;
          final matchesQuery = query.isEmpty ||
              entry.word.toLowerCase().contains(query.toLowerCase()) ||
              entry.meanings.any((m) => m.toLowerCase().contains(query.toLowerCase()));
          return matchesStatus && matchesQuery;
        }).toList();

        final knownInChapter = widget.chapter.words
            .where((w) => widget.store.getWordState(widget.book.id, w.word) == WordState.known).length;
        final unknownInChapter = widget.chapter.words.length - knownInChapter;

        return Scaffold(
          appBar: AppBar(
            title: Text(widget.chapter.title, style: const TextStyle(fontWeight: FontWeight.w800)),
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
                          onChanged: (value) => setState(() => query = value.trim()),
                          decoration: InputDecoration(
                            hintText: 'Search words or meanings',
                            prefixIcon: const Icon(Icons.search),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(color: Color(0xFFE8ECE7)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(color: Color(0xFFE8ECE7)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '$unknownInChapter unknown/review  •  $knownInChapter known',
                                style: const TextStyle(color: Colors.black54, fontSize: 13),
                              ),
                            ),
                            const Text('Show known', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            Switch(
                              value: showKnown,
                              onChanged: (value) => setState(() => showKnown = value),
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
                                style: const TextStyle(color: Colors.black54, fontSize: 16),
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                            itemCount: visible.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final entry = visible[index];
                              final state = widget.store.getWordState(widget.book.id, entry.word);
                              
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
                                    ? DismissDirection.startToEnd // Swipe right on known makes it showAgain
                                    : DismissDirection.endToStart, // Swipe left on unknown makes it known
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
                                      Text('Known', style: TextStyle(color: Color(0xFF27845B), fontWeight: FontWeight.bold)),
                                      SizedBox(width: 8),
                                      Icon(Icons.check_circle, color: Color(0xFF27845B)),
                                    ],
                                  ),
                                ),
                                confirmDismiss: (direction) async {
                                  if (state == WordState.known && direction == DismissDirection.startToEnd) {
                                    widget.store.setWordState(widget.book.id, entry.word, WordState.showAgain);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Moved to Show Again'), duration: Duration(milliseconds: 600)),
                                    );
                                  } else if (state != WordState.known && direction == DismissDirection.endToStart) {
                                    widget.store.setWordState(widget.book.id, entry.word, WordState.known);
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
                                  return false; // Prevent card from permanently disappearing from active view filters until state updates
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
                                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                                              ),
                                              const SizedBox(height: 5),
                                              Text(
                                                entry.meanings.isEmpty
                                                    ? 'বাংলা অর্থ পাওয়া যায়নি'
                                                    : entry.meanings.join('  •  '),
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  height: 1.45,
                                                  color: entry.meanings.isEmpty
                                                      ? Colors.black38
                                                      : const Color(0xFF426B59),
                                                ),
                                              ),
                                              if (badgeText.isNotEmpty && (showKnown || state == WordState.showAgain))
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
                                        // Center/Left Toggle Action Button (Unknown <-> Known)
                                        IconButton(
                                          tooltip: state == WordState.known ? 'Mark unknown' : 'Mark known',
                                          onPressed: () {
                                            final next = state == WordState.known 
                                                ? WordState.unknown 
                                                : WordState.known;
                                            widget.store.setWordState(widget.book.id, entry.word, next);
                                            if (next == WordState.known) {
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
                                        // Dedicated Right Button for "Show Again"
                                        IconButton(
                                          tooltip: 'Mark as Show Again',
                                          onPressed: () {
                                            widget.store.setWordState(widget.book.id, entry.word, WordState.showAgain);
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
                            },
                          ),
                  ),
                ],
              ),
              // Compact Bottom-Left Slider for "Mark all known" action
              Positioned(
                left: 16,
                bottom: 16,
                child: Container(
                  width: 150,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: const Color(0xFF356859).withOpacity(0.3)),
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
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 22),
                          overlayColor: Colors.transparent,
                        ),
                        child: Slider(
                          value: _sliderValue,
                          onChanged: (val) {
                            setState(() => _sliderValue = val);
                            if (val == 1.0) {
                              widget.store.markAllChapterKnown(widget.book.id, widget.chapter);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('✨ All eligible words marked known (Show Again protected)!'),
                                  backgroundColor: Color(0xFF27845B),
                                ),
                              );
                              Future.delayed(const Duration(milliseconds: 300), () {
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
    final known = store.knownCount(book.id);
    final progress = total == 0 ? 0.0 : (known / total).clamp(0.0, 1.0).toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Book progress', style: TextStyle(fontWeight: FontWeight.w700)),
                Text('$known / $total known', style: const TextStyle(color: Colors.black54, fontSize: 13)),
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