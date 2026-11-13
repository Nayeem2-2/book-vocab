class WordEntry {
  WordEntry({required this.word, required this.meanings});

  final String word;
  final List<String> meanings;

  Map<String, dynamic> toJson() => {'word': word, 'meanings': meanings};

  factory WordEntry.fromJson(Map<String, dynamic> json) => WordEntry(
        word: (json['word'] ?? '').toString(),
        meanings: (json['meanings'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

class ChapterData {
  ChapterData({
    required this.title,
    required this.pageRange,
    required this.words,
    this.imagePath,
    this.id,
  });

  // Mutable so renaming a page preserves its identity and all live references.
  String title;
  final String pageRange;
  final List<WordEntry> words;
  final String? imagePath;
  final String? id;

  /// Stable identity for image pages, including pages loaded from older metadata.
  String get stableId => id ?? imagePath ?? '$title|$pageRange';
}

class PartData {
  PartData({required this.title, required this.pageRange, required this.chapters});
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
    this.isImageBook = false,
    this.pages = const [],
  });

  final String id;
  String name;
  final String fileName;
  final List<PartData> parts;
  final String jsonPath;
  final bool isImageBook;
  final List<ChapterData> pages;

  List<ChapterData> get allChapters =>
      isImageBook ? pages : [for (final p in parts) ...p.chapters];
}

enum WordState { unknown, known, showAgain }

class PracticeCounts {
  const PracticeCounts(this.unknown, this.showAgain);
  final int unknown;
  final int showAgain;
  int get total => unknown + showAgain;
}

class PlayChoice {
  const PlayChoice({required this.unknown, required this.showAgain});
  final bool unknown;
  final bool showAgain;
}
