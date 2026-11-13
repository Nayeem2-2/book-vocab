import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

class DictionaryService {
  static const source = 'https://raw.githubusercontent.com/Nafisa41/Dictionary--English-to-Bangla-/master/Database/E2Bdatabase.json';
  Map<String, List<String>> _lookup = {};
  Future<void>? _loading;
  bool get isLoaded => _lookup.isNotEmpty;

  String normalize(String value) => unorm.nfc(value.trim().toLowerCase());

  Future<void> load({bool forceDownload = false}) async {
    if (_lookup.isNotEmpty && !forceDownload) return;
    if (_loading != null && !forceDownload) return _loading!;
    final task = _loadInternal(forceDownload: forceDownload);
    _loading = task;
    try { await task; } finally { if (identical(_loading, task)) _loading = null; }
  }

  Future<void> _loadInternal({required bool forceDownload}) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/english_bangla_dictionary.json');
    if (await file.exists() && !forceDownload) {
      try {
        _build(jsonDecode(await file.readAsString()));
        if (_lookup.isNotEmpty) return;
      } catch (_) {}
    }
    final response = await http.get(Uri.parse(source)).timeout(const Duration(seconds: 45));
    if (response.statusCode != 200) throw HttpException('Dictionary download failed (${response.statusCode}).');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    _build(decoded);
    if (_lookup.isEmpty) throw const FormatException('Dictionary file contains no usable entries.');
    await file.writeAsBytes(response.bodyBytes, flush: true);
  }

  void _build(dynamic data) {
    dynamic entries = data;
    if (data is Map) entries = data['words'] ?? data.values.toList();
    if (entries is! List) throw const FormatException('Unexpected dictionary format.');
    final map = <String, List<String>>{};
    for (final entry in entries) {
      if (entry is! Map || entry['en'] == null) continue;
      final key = normalize(entry['en'].toString());
      if (key.isEmpty) continue;
      final raw = entry['bn'];
      final values = raw is List ? raw : [raw];
      final meanings = map.putIfAbsent(key, () => <String>[]);
      for (final value in values) {
        if (value == null) continue;
        final meaning = value.toString().trim();
        if (meaning.isNotEmpty && !meanings.contains(meaning)) meanings.add(meaning);
      }
    }
    _lookup = map;
  }

  List<String> meaningsFor(String word) => List.unmodifiable(_lookup[normalize(word)] ?? const []);
}
