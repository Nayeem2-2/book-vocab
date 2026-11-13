import 'package:flutter/foundation.dart';

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
