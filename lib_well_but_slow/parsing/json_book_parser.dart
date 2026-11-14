import '../models/book_models.dart';
import '../services/book_store.dart';

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
