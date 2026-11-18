import 'dart:convert';

import 'package:flutter/foundation.dart' show compute, ValueListenable, ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Loads the English-to-Bangla dictionary bundled with the application.
///
/// The JSON file is an application asset, not a downloaded/cache file. This
/// keeps dictionary lookup available offline from the first launch onward.
class DictionaryService {
  static const String assetPath =
      'assets/dictionary/E2Bdatabase.json';

  Map<String, List<String>> _lookup = <String, List<String>>{};
  Future<void>? _loading;
  final ValueNotifier<bool> _loadedNotifier = ValueNotifier<bool>(false);

  bool get isLoaded => _lookup.isNotEmpty;
  ValueListenable<bool> get loadedListenable => _loadedNotifier;

  String normalize(String value) =>
      unorm.nfc(value.trim().toLowerCase());

  /// Loads the bundled JSON once. Concurrent callers share the same future.
  Future<void> load() async {
    if (isLoaded) return;
    if (_loading != null) return _loading!;

    final task = _loadBundledAsset();
    _loading = task;
    try {
      await task;
    } finally {
      if (identical(_loading, task)) _loading = null;
    }
  }

  Future<void> _loadBundledAsset() async {
    final jsonString = await rootBundle.loadString(assetPath);

    // JSON decoding and index construction happen away from the UI isolate.
    final parsed = await compute<String, Map<String, List<String>>>(
      _parseDictionaryJson,
      jsonString,
      debugLabel: 'parse-english-bangla-dictionary',
    );

    if (parsed.isEmpty) {
      throw const FormatException(
        'The bundled dictionary contains no usable English–Bangla entries.',
      );
    }

    _lookup = parsed;
    _loadedNotifier.value = true;
  }

  List<String> meaningsFor(String word) =>
      List<String>.unmodifiable(_lookup[normalize(word)] ?? const <String>[]);
}

/// Top-level so Flutter can execute it in a background isolate via [compute].
Map<String, List<String>> _parseDictionaryJson(String jsonString) {
  final dynamic data = jsonDecode(jsonString);
  dynamic entries = data;

  // Preserve the dictionary format supported by the previous loader: either
  // a top-level list or an object containing `words`.
  if (data is Map) {
    entries = data['words'] ?? data.values.toList();
  }
  if (entries is! List) {
    throw const FormatException('Unexpected dictionary JSON structure.');
  }

  final map = <String, List<String>>{};
  for (final entry in entries) {
    if (entry is! Map || entry['en'] == null) continue;

    final key = unorm.nfc(
      entry['en'].toString().trim().toLowerCase(),
    );
    if (key.isEmpty) continue;

    final rawMeanings = entry['bn'];
    final values = rawMeanings is List ? rawMeanings : <dynamic>[rawMeanings];
    final meanings = map.putIfAbsent(key, () => <String>[]);

    for (final value in values) {
      if (value == null) continue;
      final meaning = value.toString().trim();
      if (meaning.isNotEmpty && !meanings.contains(meaning)) {
        meanings.add(meaning);
      }
    }
  }

  return map;
}
