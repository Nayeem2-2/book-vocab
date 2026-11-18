import 'dart:async';
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

  /// Word states are global across books, but isolated per Firebase account.
  /// The active account's snapshot is stored in Accounts/word_states_<uid>.json.
  final Set<String> _known = {};
  final Set<String> _showAgain = {};
  String? _activeAccountUid;
  String? _activeLibraryUid;
  final Map<String, int> _libraryTombstones = <String, int>{};
  int _libraryServerTimeOffsetMs = 0;
  bool _accountWordStatesLoaded = false;
  bool _hasLocalAccountCache = false;

  /// A new account with no local cache must not edit words until its first
  /// successful cloud read/write establishes which snapshot belongs to it.
  final ValueNotifier<bool> wordStatesReady = ValueNotifier<bool>(false);

  String? get activeAccountUid => _activeAccountUid;
  bool get hasLocalAccountCache => _hasLocalAccountCache;

  static String accountStorageKey(String uid) =>
      base64Url.encode(utf8.encode(uid)).replaceAll('=', '');

  final Map<String, Set<String>> _uniqueCache = {};
  final Map<String, int> _knownCountCache = {};
  final Map<String, int> _showAgainCountCache = {};
  final Map<String, Future<void>> _bookWordCacheFutures = {};
  final Map<String, int> _bookWordCacheGenerations = {};

  // Word-state updates are intentionally separate from structural store
  // notifications. A single status tap must not rebuild Books/Pages/App bars.
  final ValueNotifier<int> wordStateRevision = ValueNotifier<int>(0);
  /// Structural/content revision observed by the account library sync service.
  final ValueNotifier<int> libraryRevision = ValueNotifier<int>(0);
  final Map<String, _WordStateSignal> _wordStateSignals = {};
  static const int _maxWordStateSignals = 512;
  final Map<String, _PracticeScopeCache> _practiceScopeCache = {};
  static const int _maxPracticeScopeCaches = 8;

  Future<void> _saveChain = Future.value();
  Future<void> _localMetadataChain = Future.value();
  int _serverTimeOffsetMs = 0;

  /// Supplies Firebase's estimated server/device clock offset for word-state
  /// timestamps. Until sync obtains an offset, the device clock is used.
  void setServerTimeOffsetMs(int offset) {
    _serverTimeOffsetMs = offset;
  }

  void setLibraryServerTimeOffsetMs(int offset) {
    _libraryServerTimeOffsetMs = offset;
    final uid = _activeLibraryUid;
    if (uid != null) {
      unawaited(_prefs.setInt(
        'library_server_time_offset_ms_${accountStorageKey(uid)}',
        offset,
      ).then<void>((_) {}));
    }
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    // Preserve the old device-global file for recovery, but never assign it
    // automatically to whichever Google account happens to sign in first.
    await _backupLegacyGlobalWordStates();
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
            final savedName = (page['name'] ?? '').toString().trim();
            final legacyNameMatch = RegExp(
              r'^Page[- ](\d+)(?: \((\d+)\))?$',
              caseSensitive: false,
            ).firstMatch(savedName);
            final savedNumber = int.tryParse(page['pageNumber']?.toString() ?? '');
            final pageNumber = savedNumber != null && savedNumber > 0
                ? savedNumber
                : int.tryParse(legacyNameMatch?.group(1) ?? '') ?? pageIndex + 1;
            // Convert the old generated "Page-1" label to the new default
            // "Page 1" label. Custom page names remain untouched.
            final savedDefaultName = page['isDefaultName'] as bool?;
            final isDefaultName = savedDefaultName ??
                (legacyNameMatch != null || savedName.isEmpty);
            final legacySuffix = legacyNameMatch?.group(2);
            final pageName = legacyNameMatch == null
                ? (savedName.isEmpty ? 'Page $pageNumber' : savedName)
                : 'Page $pageNumber${legacySuffix == null ? '' : ' ($legacySuffix)'}';
            pages.add(ChapterData(
              id: (page['id'] ?? imagePath ?? '${id}_$pageIndex').toString(),
              title: pageName,
              pageRange: '',
              pageNumber: pageNumber,
              isDefaultName: isDefaultName,
              description: (page['description'] ?? '').toString(),
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

  // ── Account-specific word-state files ──

  Future<Directory> _accountStatesDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/Accounts');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> _legacyGlobalKnownFile() async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}/known_words.json');
  }

  Future<File> _accountKnownFile(String uid) async {
    final directory = await _accountStatesDirectory();
    final token = accountStorageKey(uid);
    return File('${directory.path}/word_states_$token.json');
  }

  Future<File> _accountSyncedFile(String uid) async {
    final directory = await _accountStatesDirectory();
    final token = accountStorageKey(uid);
    return File('${directory.path}/word_states_synced_$token.json');
  }

  Future<File> _knownFile() async {
    final uid = _activeAccountUid;
    if (uid == null) {
      throw StateError('No Google account is active for word-state storage.');
    }
    return _accountKnownFile(uid);
  }

  Future<void> _backupLegacyGlobalWordStates() async {
    try {
      final legacy = await _legacyGlobalKnownFile();
      final backup = File('${legacy.path}.legacy-unassigned-backup');
      if (await backup.exists()) return;

      // Prefer the complete global file used by the preceding release.
      if (await legacy.exists()) {
        await legacy.copy(backup.path);
        return;
      }

      // Very old installations may still have per-book states_$id entries in
      // SharedPreferences and no global file. Preserve those in the same
      // unassigned backup format, but never load them into an account.
      final legacyKnown = <String>{};
      final legacyAgain = <String>{};
      final records = _prefs.getStringList('book_records') ?? const [];
      for (final record in records) {
        try {
          final map = jsonDecode(record) as Map<String, dynamic>;
          final id = map['id'] as String;
          final states = _prefs.getStringList('states_$id') ?? const [];
          for (final entry in states) {
            final separator = entry.lastIndexOf(':');
            if (separator <= 0) continue;
            final word = normalizeWord(entry.substring(0, separator));
            final state = entry.substring(separator + 1);
            if (word.isEmpty) continue;
            if (state == 'known') {
              legacyKnown.add(word);
              legacyAgain.remove(word);
            } else if (state == 'showAgain' && !legacyKnown.contains(word)) {
              legacyAgain.add(word);
            }
          }
        } catch (_) {
          // Ignore one malformed legacy book record; preserve the others.
        }
      }

      if (legacyKnown.isEmpty && legacyAgain.isEmpty) return;
      final known = legacyKnown.toList()..sort();
      final again = legacyAgain.toList()..sort();
      await backup.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'version': 1,
          'known': known,
          'showAgain': again,
          'note': 'Unassigned legacy device data; not associated with a Firebase UID.',
        }),
        flush: true,
      );
    } catch (error) {
      // Backup failure must not prevent access to books or authentication.
      debugPrint('Could not preserve legacy global word states: $error');
    }
  }

  /// Activates exactly one account's local cache. The previous account's
  /// in-memory data is cleared before the new account's file is read.
  /// Returns true when a valid account-specific cache existed.
  Future<bool> activateAccount(String uid) async {
    if (_activeAccountUid == uid && _accountWordStatesLoaded) {
      return _hasLocalAccountCache;
    }

    // Complete queued writes for the previous UID before switching paths.
    await flushPendingWordStateWrites();
    _activeAccountUid = uid;
    // Reuse the last known Firebase clock offset while offline so local
    // changes still receive timestamps in the same time domain as cloud data.
    _serverTimeOffsetMs = _prefs.getInt('word_states_server_time_offset_ms') ?? 0;
    _accountWordStatesLoaded = false;
    _hasLocalAccountCache = false;
    wordStatesReady.value = false;

    _known.clear();
    _showAgain.clear();
    _invalidateAllWordCaches();
    _refreshWordSignals();
    wordStateRevision.value++;

    final file = await _accountKnownFile(uid);
    var sourceFile = file;
    var restoredFromSyncedBaseline = false;
    if (!await sourceFile.exists()) {
      // The known-good snapshot is also a recoverable local cache. This covers
      // a crash between saving the baseline and the ordinary account file.
      final baseline = await _accountSyncedFile(uid);
      if (await baseline.exists()) {
        sourceFile = baseline;
        restoredFromSyncedBaseline = true;
      }
    }
    if (await sourceFile.exists()) {
      try {
        final decoded = jsonDecode(await sourceFile.readAsString());
        _mergeAccountWordStateJson(decoded);
        _hasLocalAccountCache = true;
        // Keep word-state controls gated until Firebase confirms this UID's
        // cloud snapshot, or reports that it is offline and this local cache
        // must be used. This prevents editing stale cached data before login
        // reconciliation completes.
        wordStatesReady.value = false;
        _refreshWordSignals();
        if (restoredFromSyncedBaseline) {
          await file.writeAsString(_encode(), flush: true);
        }
      } catch (error) {
        // Preserve malformed account data for recovery. If the main cache is
        // corrupt, attempt this same UID's last-known-good snapshot; never
        // fall back to the device-global legacy file or another UID.
        final corrupt = File(
          '${sourceFile.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
        );
        await sourceFile.copy(corrupt.path);
        _known.clear();
        _showAgain.clear();
        if (!restoredFromSyncedBaseline) {
          final baseline = await _accountSyncedFile(uid);
          if (await baseline.exists()) {
            try {
              _mergeAccountWordStateJson(
                jsonDecode(await baseline.readAsString()),
              );
              _hasLocalAccountCache = true;
              wordStatesReady.value = false;
              _refreshWordSignals();
              await file.writeAsString(_encode(), flush: true);
            } catch (_) {
              final badBaseline = File(
                '${baseline.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
              );
              await baseline.copy(badBaseline.path);
              _known.clear();
              _showAgain.clear();
            }
          }
        }
      }
    }
    _accountWordStatesLoaded = true;
    return _hasLocalAccountCache;
  }

  /// Loads only the selected UID's newly account-owned books. Legacy books
  /// (ownerUid == null) remain device-local and are never uploaded.
  Future<void> activateLibraryAccount(String uid) async {
    if (_activeLibraryUid == uid) return;
    _libraryServerTimeOffsetMs = _prefs.getInt(
          'library_server_time_offset_ms_${accountStorageKey(uid)}',
        ) ??
        0;
    books.removeWhere((book) => book.ownerUid != null);
    _libraryTombstones.clear();
    _activeLibraryUid = uid;

    final root = await _accountLibraryDirectory(uid);
    final manifest = File('${root.path}/manifest.json');
    if (await manifest.exists()) {
      try {
        final decoded = jsonDecode(await manifest.readAsString());
        if (decoded is Map) {
          final tombstones = decoded['tombstones'];
          if (tombstones is Map) {
            for (final entry in tombstones.entries) {
              final stamp = (entry.value as num?)?.toInt();
              if (stamp != null) _libraryTombstones[entry.key.toString()] = stamp;
            }
          }
          final records = decoded['books'];
          if (records is List) {
            for (final rawRecord in records) {
              if (rawRecord is! Map) continue;
              final record = Map<String, dynamic>.from(rawRecord);
              final id = (record['id'] ?? '').toString();
              if (id.isEmpty) continue;
              final name = (record['name'] ?? 'Untitled book').toString();
              final modifiedAt = (record['modifiedAt'] as num?)?.toInt() ?? 0;
              final type = (record['type'] ?? 'json').toString();
              try {
                if (type == 'image') {
                  final folder = Directory('${root.path}/books/$id');
                  final metadata = File('${folder.path}/book.json');
                  if (!await metadata.exists()) continue;
                  final data = jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
                  final pages = <ChapterData>[];
                  for (final rawPage in (data['pages'] as List? ?? const [])) {
                    if (rawPage is! Map) continue;
                    final page = Map<String, dynamic>.from(rawPage);
                    pages.add(ChapterData(
                      id: (page['id'] ?? '').toString(),
                      title: (page['name'] ?? 'Untitled page').toString(),
                      pageRange: '',
                      pageNumber: (page['pageNumber'] as num?)?.toInt() ?? 1,
                      isDefaultName: page['isDefaultName'] == true,
                      description: (page['description'] ?? '').toString(),
                      imagePath: page['imagePath']?.toString(),
                      words: (page['words'] as List? ?? const [])
                          .whereType<Map>()
                          .map((word) => WordEntry.fromJson(Map<String, dynamic>.from(word)))
                          .toList(),
                    ));
                  }
                  books.add(BookData(
                    id: id,
                    name: name,
                    fileName: '',
                    parts: const [],
                    jsonPath: metadata.path,
                    isImageBook: true,
                    pages: pages,
                    ownerUid: uid,
                    modifiedAt: modifiedAt,
                  ));
                } else {
                  final file = File('${root.path}/books/$id.json');
                  if (!await file.exists()) continue;
                  final decodedBook = jsonDecode(await file.readAsString());
                  books.add(BookData(
                    id: id,
                    name: name,
                    fileName: (record['fileName'] ?? 'book.json').toString(),
                    parts: JsonBookParser.parseParts(decodedBook),
                    jsonPath: file.path,
                    ownerUid: uid,
                    modifiedAt: modifiedAt,
                  ));
                }
              } catch (error) {
                debugPrint('Could not load account book $id: $error');
              }
            }
          }
        }
      } catch (error) {
        final backup = File('${manifest.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
        await manifest.copy(backup.path);
        debugPrint('Account library manifest was corrupt and has been backed up: $error');
      }
    }
    _invalidateAllWordCaches();
    notifyListeners();
  }

  Future<Directory> _accountLibraryDirectory(String uid) async {
    final root = await _accountStatesDirectory();
    final directory = Directory('${root.path}/${accountStorageKey(uid)}/Library');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _booksDirectory({String? uid}) async {
    if (uid != null) {
      final library = await _accountLibraryDirectory(uid);
      final directory = Directory('${library.path}/books');
      if (!await directory.exists()) await directory.create(recursive: true);
      return directory;
    }
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/books');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  List<BookData> accountBooks(String uid) =>
      books.where((book) => book.ownerUid == uid).toList(growable: false);

  Map<String, int> get accountLibraryTombstones =>
      Map<String, int>.unmodifiable(_libraryTombstones);

  int _newLibraryTimestamp() =>
      DateTime.now().millisecondsSinceEpoch + _libraryServerTimeOffsetMs;

  void _markAccountBookModified(BookData book) {
    if (book.ownerUid == null) return;
    final next = _newLibraryTimestamp();
    book.modifiedAt = next > book.modifiedAt ? next : book.modifiedAt + 1;
    libraryRevision.value++;
  }

  void acknowledgeAccountBookSynced(String uid, String bookId, int serverTimestamp) {
    final book = books.cast<BookData?>().firstWhere(
      (item) => item?.ownerUid == uid && item?.id == bookId,
      orElse: () => null,
    );
    if (book == null) return;
    book.modifiedAt = serverTimestamp;
    unawaited(_saveBookRecords());
  }

  Future<Map<String, dynamic>> exportAccountBook(BookData book) async {
    if (book.ownerUid == null || book.ownerUid != _activeLibraryUid) {
      throw StateError('Only the active account library can be exported.');
    }
    if (book.isImageBook) {
      return {
        'schemaVersion': 1,
        'id': book.id,
        'name': book.name,
        'type': 'image',
        'fileName': '',
        'modifiedAt': book.modifiedAt,
        // Store the complete ordered page metadata as JSON text. This keeps
        // empty lists, OCR word arrays and Bangla meanings intact in RTDB,
        // whose tree model may otherwise represent arrays as numeric-key maps.
        'pagesJson': jsonEncode(book.pages.map((page) => {
          'id': page.stableId,
          'name': page.title,
          'pageNumber': page.pageNumber,
          'isDefaultName': page.isDefaultName,
          'description': page.description,
          'words': page.words.map((word) => word.toJson()).toList(),
          // imagePath and image bytes are deliberately excluded.
        }).toList()),
      };
    }
    final rawContent = await File(book.jsonPath).readAsString();
    return {
      'schemaVersion': 1,
      'id': book.id,
      'name': book.name,
      'type': 'json',
      'fileName': book.fileName,
      'modifiedAt': book.modifiedAt,
      'content': rawContent,
    };
  }

  Future<void> applyRemoteAccountBook(String uid, Map<String, dynamic> record,
      {required int serverUpdatedAt}) async {
    if (_activeLibraryUid != uid) return;
    final id = (record['id'] ?? '').toString();
    if (id.isEmpty) return;
    if (id == '.' || id == '..' || id.contains('/') || id.contains('\\') ||
        RegExp(r'[\x00-\x1F]').hasMatch(id)) {
      throw FormatException(
        'Cloud book ID contains characters that cannot safely be used in a local file path.',
      );
    }
    final type = (record['type'] ?? '').toString();
    final name = (record['name'] ?? 'Untitled book').toString();
    final root = await _booksDirectory(uid: uid);
    final existingIndex = books.indexWhere((book) => book.id == id && book.ownerUid == uid);
    final existing = existingIndex >= 0 ? books[existingIndex] : null;

    BookData incoming;
    if (type == 'image') {
      final folder = Directory('${root.path}/$id');
      await Directory('${folder.path}/pages').create(recursive: true);
      final existingPaths = <String, String>{
        for (final page in existing?.pages ?? const <ChapterData>[])
          if (page.imagePath != null && page.imagePath!.isNotEmpty && File(page.imagePath!).existsSync())
            page.stableId: page.imagePath!,
      };
      final incomingIds = <String>{};
      final pages = <ChapterData>[];
      final rawPagesField = record['pagesJson'];
      final decodedPages = rawPagesField is String
          ? jsonDecode(rawPagesField)
          : record['pages']; // Backward compatibility with the first draft.
      final rawPages = <dynamic>[];
      if (decodedPages is List) {
        rawPages.addAll(decodedPages);
      } else if (decodedPages is Map) {
        final entries = decodedPages.entries.toList()
          ..sort((a, b) {
            final aIndex = int.tryParse(a.key.toString());
            final bIndex = int.tryParse(b.key.toString());
            if (aIndex != null && bIndex != null) return aIndex.compareTo(bIndex);
            return a.key.toString().compareTo(b.key.toString());
          });
        rawPages.addAll(entries.map((entry) => entry.value));
      } else {
        throw const FormatException('Cloud image-book page data is missing or malformed.');
      }
      for (final rawPage in rawPages) {
        if (rawPage is! Map) {
          throw const FormatException('A cloud image-book page record is malformed.');
        }
        final page = Map<String, dynamic>.from(rawPage);
        final pageId = (page['id'] ?? '').toString();
        if (pageId.isEmpty) {
          throw const FormatException('A cloud image-book page has no stable ID.');
        }
        incomingIds.add(pageId);
        pages.add(ChapterData(
          id: pageId,
          title: (page['name'] ?? 'Untitled page').toString(),
          pageRange: '',
          pageNumber: (page['pageNumber'] as num?)?.toInt() ?? 1,
          isDefaultName: page['isDefaultName'] == true,
          description: (page['description'] ?? '').toString(),
          imagePath: existingPaths[pageId],
          words: (page['words'] as List? ?? const [])
              .whereType<Map>()
              .map((word) => WordEntry.fromJson(Map<String, dynamic>.from(word)))
              .toList(),
        ));
      }
      // Remove local photographs for pages explicitly deleted by a newer cloud record.
      if (existing != null) {
        for (final oldPage in existing.pages) {
          if (!incomingIds.contains(oldPage.stableId) && oldPage.imagePath != null) {
            await File(oldPage.imagePath!).delete().catchError((_) => File(oldPage.imagePath!));
          }
        }
      }
      final metadata = File('${folder.path}/book.json');
      final localData = {
        'version': 1,
        'name': name,
        'pages': pages.map((page) => {
          'id': page.stableId,
          'name': page.title,
          'pageNumber': page.pageNumber,
          'isDefaultName': page.isDefaultName,
          'description': page.description,
          'imagePath': page.imagePath,
          'words': page.words.map((word) => word.toJson()).toList(),
        }).toList(),
      };
      await metadata.writeAsString(const JsonEncoder.withIndent('  ').convert(localData), flush: true);
      incoming = BookData(
        id: id, name: name, fileName: '', parts: const [],
        jsonPath: metadata.path, isImageBook: true, pages: pages,
        ownerUid: uid, modifiedAt: serverUpdatedAt,
      );
    } else if (type == 'json') {
      final content = record['content'];
      if (content is! String) throw const FormatException('Cloud JSON book content is missing.');
      final decoded = jsonDecode(content);
      final parts = JsonBookParser.parseParts(decoded);
      if (parts.isEmpty) throw const FormatException('Cloud JSON book has no chapters.');
      final file = File('${root.path}/$id.json');
      await file.writeAsString(content, flush: true);
      incoming = BookData(
        id: id, name: name,
        fileName: (record['fileName'] ?? 'book.json').toString(),
        parts: parts, jsonPath: file.path, ownerUid: uid,
        modifiedAt: serverUpdatedAt,
      );
    } else {
      throw FormatException('Unknown cloud book type: $type');
    }

    if (existingIndex >= 0) {
      books[existingIndex] = incoming;
    } else {
      books.add(incoming);
    }
    _libraryTombstones.remove(id);
    await _saveBookRecords();
    _invalidateBookWordCache(id);
    _clearPracticeScopeCaches();
    notifyListeners();
  }

  Future<void> removeRemoteAccountBook(String uid, String bookId) async {
    if (_activeLibraryUid != uid) return;
    final index = books.indexWhere((book) => book.id == bookId && book.ownerUid == uid);
    if (index < 0) return;
    final book = books.removeAt(index);
    if (book.isImageBook) {
      final folder = File(book.jsonPath).parent;
      if (await folder.exists()) await folder.delete(recursive: true);
    } else {
      final file = File(book.jsonPath);
      if (await file.exists()) await file.delete();
    }
    await _saveBookRecords();
    _invalidateBookWordCache(bookId);
    notifyListeners();
  }

  Future<void> acknowledgeAccountBookDeleted(String uid, String bookId) async {
    if (_activeLibraryUid != uid) return;
    _libraryTombstones.remove(bookId);
    await _saveBookRecords();
  }

  Future<void> setLibraryServerModifiedAt(
    String uid,
    String bookId,
    int expectedLocalModifiedAt,
    int serverTimestamp,
  ) async {
    if (_activeLibraryUid != uid) return;
    BookData? book;
    for (final candidate in books) {
      if (candidate.ownerUid == uid && candidate.id == bookId) {
        book = candidate;
        break;
      }
    }
    if (book == null || book.modifiedAt != expectedLocalModifiedAt) return;
    book.modifiedAt = serverTimestamp;
    await _saveBookRecords();
  }

  /// Clears active memory at logout without deleting this account's cache.
  Future<void> clearActiveAccountWordStates() async {
    await flushPendingWordStateWrites();
    _activeAccountUid = null;
    _accountWordStatesLoaded = false;
    _hasLocalAccountCache = false;
    wordStatesReady.value = false;
    _known.clear();
    _showAgain.clear();
    _invalidateAllWordCaches();
    _refreshWordSignals();
    wordStateRevision.value++;
  }

  void markWordStatesReady() {
    wordStatesReady.value = true;
  }

  /// Allows cached word-state use when Firebase explicitly reports offline.
  /// A new UID with no account cache remains locked until its first cloud
  /// snapshot has been fetched or safely initialized.
  void markCachedWordStatesReadyOffline() {
    if (_hasLocalAccountCache && _accountWordStatesLoaded) {
      wordStatesReady.value = true;
    }
  }

  void _refreshWordSignals() {
    for (final signal in _wordStateSignals.entries) {
      final refreshed = getWordState(signal.key);
      if (signal.value.value != refreshed) signal.value.value = refreshed;
    }
  }

  void _invalidateAllWordCaches() {
    final ids = <String>{
      ..._bookWordCacheFutures.keys,
      ..._uniqueCache.keys,
      ...books.map((book) => book.id),
    };
    for (final id in ids) {
      _invalidateBookWordCache(id);
    }
    _bookWordCacheFutures.clear();
    _clearPracticeScopeCaches();
  }

  /// Captures the exact uploaded/downloaded snapshot as the last known-good
  /// version for this UID. It is used if the user explicitly discards pending
  /// changes during logout.
  Future<void> markWordStateSnapshotAsSynced({
    required String uid,
    required List<String> known,
    required List<String> showAgain,
    required int updatedAt,
  }) async {
    final file = await _accountSyncedFile(uid);
    final payload = <String, dynamic>{
      'version': 1,
      'known': List<String>.from(known)..sort(),
      'showAgain': List<String>.from(showAgain)..sort(),
      'updatedAt': updatedAt,
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    if (_activeAccountUid == uid) {
      _hasLocalAccountCache = true;
      _accountWordStatesLoaded = true;
      wordStatesReady.value = true;
    }
  }

  /// True when current local states differ from the last successfully synced
  /// snapshot. Without a baseline, any non-empty local state is pending.
  Future<bool> hasUnsyncedWordStateChanges() async {
    final uid = _activeAccountUid;
    if (uid == null) return false;
    final baselineFile = await _accountSyncedFile(uid);
    if (!await baselineFile.exists()) {
      return _known.isNotEmpty || _showAgain.isNotEmpty;
    }
    try {
      final decoded = jsonDecode(await baselineFile.readAsString());
      if (decoded is! Map ||
          decoded['known'] is! List ||
          decoded['showAgain'] is! List) {
        throw const FormatException('Last-synced snapshot is incomplete.');
      }
      final known = (decoded['known'] as List)
          .map((item) => normalizeWord(item.toString()))
          .where((item) => item.isNotEmpty)
          .toSet();
      final again = (decoded['showAgain'] as List)
          .map((item) => normalizeWord(item.toString()))
          .where((item) => item.isNotEmpty && !known.contains(item))
          .toSet();
      return !_sameStringSet(_known, known) ||
          !_sameStringSet(_showAgain, again);
    } catch (_) {
      // An unreadable baseline is not permission to discard current data.
      return true;
    }
  }

  /// Restores the last successful snapshot. If this account has never
  /// synchronized, its safe baseline is an empty (all Unknown) state.
  Future<void> restoreLastSyncedWordStates() async {
    await _localMetadataChain;
    final uid = _activeAccountUid;
    if (uid == null) return;
    final baselineFile = await _accountSyncedFile(uid);
    List<String> known = const [];
    List<String> again = const [];
    var updatedAt = 0;
    if (await baselineFile.exists()) {
      final decoded = jsonDecode(await baselineFile.readAsString());
      if (decoded is! Map ||
          decoded['known'] is! List ||
          decoded['showAgain'] is! List) {
        throw const FormatException('Last-synced snapshot is incomplete.');
      }
      known = (decoded['known'] as List)
          .map((item) => item.toString()).toList();
      again = (decoded['showAgain'] as List)
          .map((item) => item.toString()).toList();
      updatedAt = (decoded['updatedAt'] as num?)?.toInt() ?? 0;
    }
    await replaceWordStates(known: known, showAgain: again);
    final prefs = await SharedPreferences.getInstance();
    final token = accountStorageKey(uid);
    final timestampKey = 'word_states_last_modified_at_$token';
    if (updatedAt > 0) {
      await prefs.setInt(timestampKey, updatedAt);
    } else {
      await prefs.remove(timestampKey);
    }
    await prefs.setBool('word_states_timestamp_server_adjusted_$token', true);
    wordStatesReady.value = true;
  }

  bool _sameStringSet(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  String _encode() {
    final known = _known.toList()..sort();
    final again = _showAgain.toList()..sort();
    return const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'known': known,
      'showAgain': again,
    });
  }


  /// Account caches and synced baselines are complete snapshots. Missing
  /// either list is corruption, not an empty list, because that could erase
  /// Show Again / Known states during account recovery.
  int _mergeAccountWordStateJson(dynamic decoded) {
    if (decoded is! Map ||
        decoded['known'] is! List ||
        decoded['showAgain'] is! List) {
      throw const FormatException(
        'Account word-state cache is incomplete or invalid.',
      );
    }
    return _mergeJson(decoded);
  }

  /// Merges imported JSON. Known wins over Show Again. User-imported older
  /// files may contain only a known list, so this parser remains permissive.
  int _mergeJson(dynamic decoded) {
    List<dynamic> knownList = const [];
    List<dynamic> againList = const [];
    if (decoded is List) {
      knownList = decoded;
    } else if (decoded is Map) {
      final knownRaw = decoded['known'];
      final againRaw = decoded['showAgain'] ?? decoded['show_again'];
      if (knownRaw is! List && againRaw is! List) {
        throw const FormatException(
          'This file has no "known" or "showAgain" list.',
        );
      }
      if (knownRaw is List) knownList = knownRaw;
      if (againRaw is List) againList = againRaw;
    } else {
      throw const FormatException('Unrecognised known words file.');
    }

    final before = _known.length;
    for (final item in knownList) {
      final word = normalizeWord(item.toString());
      if (word.isEmpty) continue;
      _known.add(word);
      _showAgain.remove(word);
    }
    for (final item in againList) {
      final word = normalizeWord(item.toString());
      if (word.isEmpty || _known.contains(word)) continue;
      _showAgain.add(word);
    }
    return _known.length - before;
  }

  Future<void> _saveKnownWords() {
    final uid = _activeAccountUid;
    if (uid == null) return Future<void>.value();
    // Capture both UID and payload now: a queued write must never land in a
    // different account's file after an account switch.
    final fileFuture = _accountKnownFile(uid);
    final payload = _encode();
    _saveChain = _saveChain.then((_) async {
      final file = await fileFuture;
      await file.writeAsString(payload, flush: true);
      if (_activeAccountUid == uid) _hasLocalAccountCache = true;
    }).catchError((Object error) {
      debugPrint('Could not persist account word states: $error');
    });
    return _saveChain;
  }

  Future<void> _recordLocalWordStateModification() {
    final uid = _activeAccountUid;
    if (uid == null) return Future<void>.value();
    final token = accountStorageKey(uid);
    final timestamp =
        DateTime.now().millisecondsSinceEpoch + _serverTimeOffsetMs;
    final key = 'word_states_last_modified_at_$token';
    _localMetadataChain = _localMetadataChain.then((_) async {
      await _prefs.setInt(key, timestamp);
    });
    return _localMetadataChain;
  }

  /// Waits for any word-state timestamp and file writes already scheduled by
  /// the UI. Manual sync/logout may be tapped immediately after a state change.
  Future<void> flushPendingWordStateWrites() async {
    while (true) {
      final metadataPending = _localMetadataChain;
      final filesPending = _saveChain;
      await metadataPending;
      await filesPending;
      // A new edit may have queued another timestamp/file write while the
      // previous futures were completing. Continue until the queue is stable.
      if (identical(metadataPending, _localMetadataChain) &&
          identical(filesPending, _saveChain)) {
        return;
      }
    }
  }

  /// Replaces the global word-state collections with a normalized snapshot.
  /// If nothing changed, caches and revisions are deliberately left untouched.
  Future<void> replaceWordStates({
    required List<String> known,
    required List<String> showAgain,
  }) async {
    final nextKnown = <String>{};
    final nextAgain = <String>{};
    for (final item in known) {
      final key = normalizeWord(item);
      if (key.isNotEmpty) nextKnown.add(key);
    }
    for (final item in showAgain) {
      final key = normalizeWord(item);
      if (key.isNotEmpty && !nextKnown.contains(key)) nextAgain.add(key);
    }

    if (_sameStringSet(_known, nextKnown) &&
        _sameStringSet(_showAgain, nextAgain)) {
      return;
    }

    _known
      ..clear()
      ..addAll(nextKnown);
    _showAgain
      ..clear()
      ..addAll(nextAgain);
    _refreshWordSignals();
    _invalidateAllWordCaches();
    wordStateRevision.value++;
    await _saveKnownWords();
  }

  /// Compact complete snapshot used by account-specific cloud synchronization.
  Map<String, List<String>> wordStateSnapshot() {
    final known = _known.toList()..sort();
    final again = _showAgain.toList()..sort();
    return {'known': known, 'showAgain': again};
  }

  /// Creates a safety copy before a cloud snapshot replaces local word states.
  Future<void> backupKnownWords() async {
    final file = await _knownFile();
    if (!await file.exists()) return;
    final backup = File('${file.path}.backup-${DateTime.now().millisecondsSinceEpoch}');
    await file.copy(backup.path);
  }

  /// Lets the user save known_words.json anywhere. Returns the path or null.
  Future<String?> exportKnownWords() async {
    if (!wordStatesReady.value || _activeAccountUid == null) {
      throw StateError('Connect to load this account’s vocabulary before exporting word states.');
    }
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
    if (!wordStatesReady.value || _activeAccountUid == null) {
      throw StateError('Connect to the internet once to load this account’s vocabulary before importing word states.');
    }
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
    final before = wordStateSnapshot();
    final added = _mergeJson(decoded);
    final after = wordStateSnapshot();
    final changed = !_sameStringSet(before['known']!.toSet(), after['known']!.toSet()) ||
        !_sameStringSet(before['showAgain']!.toSet(), after['showAgain']!.toSet());
    if (changed) {
      _refreshCachedWordCounts();
      wordStateRevision.value++;
      await _recordLocalWordStateModification();
      await _saveKnownWords();
    }
    return added;
  }

  // ── Books ──


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
    if (!wordStatesReady.value || _activeAccountUid == null) return;
    final key = normalizeWord(word);
    if (key.isEmpty) return;
    if (!_applyWordState(key, newState)) return;
    // Notify the sync debounce immediately; the service flushes the timestamp
    // before reading it, so manual sync cannot outrun this async write.
    wordStateRevision.value++;
    await _recordLocalWordStateModification();
    await _saveKnownWords();
  }

  Future<void> markAllChapterKnown(ChapterData chapter) async {
    if (!wordStatesReady.value || _activeAccountUid == null) return;
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
      await _recordLocalWordStateModification();
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
    final uid = _activeAccountUid;
    final directory = await _booksDirectory(uid: uid);
    final path = '${directory.path}/$id.json';
    await File(path).writeAsString(raw);

    final name = JsonBookParser.bookName(decoded, picked.name);
    final book = BookData(
      id: id,
      name: name,
      fileName: picked.name,
      parts: parts,
      jsonPath: path,
      ownerUid: uid,
      modifiedAt: uid == null ? 0 : _newLibraryTimestamp(),
    );
    books.add(book);
    if (uid != null) libraryRevision.value++;
    await _saveBookRecords();
    notifyListeners();
    return id;
  }

  Future<BookData> createImageBook(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Please enter a book name.');
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final uid = _activeAccountUid;
    final root = await _booksDirectory(uid: uid);
    final folder = Directory('${root.path}/$id');
    await Directory('${folder.path}/pages').create(recursive: true);
    final book = BookData(id: id, name: clean, fileName: '', parts: const [], jsonPath: '${folder.path}/book.json', isImageBook: true, pages: [], ownerUid: uid, modifiedAt: uid == null ? 0 : _newLibraryTimestamp());
    books.add(book);
    if (uid != null) libraryRevision.value++;
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
                'pageNumber': page.pageNumber,
                'isDefaultName': page.isDefaultName,
                'description': page.description,
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

  Future<void> addScannedPage(
    BookData book,
    Uint8List bytes, {
    bool notify = true,
  }) async {
    if (!book.isImageBook) {
      throw Exception('Pages can only be added to an image book.');
    }
    if (!dictionary.isLoaded) await dictionary.load();

    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('This image format could not be opened.');

    // Page numbers are independent from list length. After manual renumbering,
    // the next imported page is always highest existing number + 1.
    final highestNumber = book.pages.fold<int>(
      0,
      (highest, page) => page.pageNumber > highest ? page.pageNumber : highest,
    );
    final pageNumber = highestNumber + 1;
    final pageName = _uniquePageName(book, 'Page $pageNumber');
    final pageId = DateTime.now().microsecondsSinceEpoch.toString();
    final jpg = img.encodeJpg(decoded, quality: 90);
    final imagePath =
        '${File(book.jsonPath).parent.path}/pages/page_$pageId.jpg';

    await File(imagePath).writeAsBytes(jpg, flush: true);
    try {
      final words = await _ocr.extractWords(imagePath, dictionary);
      book.pages.add(ChapterData(
        id: pageId,
        title: pageName,
        pageNumber: pageNumber,
        isDefaultName: true,
        pageRange: '',
        words: words,
        imagePath: imagePath,
      ));
      await _saveImageMetadata(book);
      if (notify) await notifyImageBookPagesChanged(book);
    } catch (_) {
      book.pages.removeWhere((page) => page.stableId == pageId);
      await File(imagePath).delete().catchError((_) => File(imagePath));
      rethrow;
    }
  }

  /// Called once after a multi-image import so the Pages route refreshes once,
  /// not once for every scanned page in the batch.
  Future<void> notifyImageBookPagesChanged(BookData book) async {
    _markAccountBookModified(book);
    await _saveBookRecords();
    _invalidateBookWordCache(book.id);
    _clearPracticeScopeCaches();
    notifyListeners();
  }

  String _uniquePageName(
    BookData book,
    String requestedName, {
    String? excludingPageId,
  }) {
    final base = requestedName.trim();
    final existingNames = book.pages
        .where((page) => page.stableId != excludingPageId)
        .map((page) => page.title.trim().toLowerCase())
        .toSet();
    if (!existingNames.contains(base.toLowerCase())) return base;

    var suffix = 1;
    while (existingNames.contains('$base ($suffix)'.toLowerCase())) {
      suffix++;
    }
    return '$base ($suffix)';
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
    _markAccountBookModified(current);
    if (current.isImageBook) await _saveImageMetadata(current);
    await _saveBookRecords();
    notifyListeners();
  }

  Future<void> renamePage(BookData book, ChapterData page, String name) async {
    await updatePageDetails(
      book,
      page,
      name: name,
      pageNumber: page.pageNumber,
      description: page.description,
    );
  }

  /// Updates a page's display name and page number without changing its stable
  /// identity, image path, vocabulary, or position in the original scan order.
  /// Duplicate page numbers are permitted; duplicate names are auto-suffixed.
  Future<void> updatePageDetails(
    BookData book,
    ChapterData page, {
    required String name,
    required int pageNumber,
    String description = '',
  }) async {
    final clean = name.trim();
    if (clean.isEmpty) throw Exception('Page name cannot be empty.');
    if (pageNumber < 1) throw Exception('Page number must be 1 or greater.');

    final index = book.pages.indexWhere(
      (candidate) => candidate.stableId == page.stableId,
    );
    if (index < 0) return;

    final current = book.pages[index];
    final numberChanged = current.pageNumber != pageNumber;
    final nameUnchanged = clean == current.title;
    final requestedName = current.isDefaultName && nameUnchanged && numberChanged
        ? 'Page $pageNumber'
        : clean;
    final uniqueName = _uniquePageName(
      book,
      requestedName,
      excludingPageId: page.stableId,
    );
    final defaultNameMatch = RegExp(
      '^Page ${RegExp.escape(pageNumber.toString())}(?: \\(\\d+\\))?\$',
      caseSensitive: false,
    ).hasMatch(requestedName);

    // Preserve the original ChapterData object so open routes and selection
    // sets continue to refer to the same scanned page.
    current.title = uniqueName;
    current.pageNumber = pageNumber;
    current.description = description.trim();
    current.isDefaultName = current.isDefaultName && nameUnchanged && numberChanged
        ? true
        : defaultNameMatch;
    _markAccountBookModified(book);
    await _saveImageMetadata(book);
    await _saveBookRecords();
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
    _markAccountBookModified(book);
    // Persist the page removal and account manifest before deleting local image
    // files. If the app closes mid-operation, the page cannot be resurrected
    // from stale metadata; at worst an unreferenced image file remains.
    await _saveImageMetadata(book);
    await _saveBookRecords();
    for (final page in removed) {
      final imagePath = page.imagePath;
      if (imagePath == null || imagePath.isEmpty) continue;
      final file = File(imagePath);
      if (await file.exists()) await file.delete();
    }
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

    for (final book in removed) {
      if (book.ownerUid != null && book.ownerUid == _activeLibraryUid) {
        _libraryTombstones[book.id] = _newLibraryTimestamp();
        libraryRevision.value++;
      }
    }
    books.removeWhere((book) => targetIds.contains(book.id));
    // Persist account tombstones before removing local files. This ensures an
    // offline deletion survives an app shutdown during file cleanup.
    await _saveBookRecords();
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
      // Account-specific word states are intentionally retained when a book is deleted.
      await _prefs.remove('states_${book.id}');
    }

    notifyListeners();
  }

  Future<void> _saveBookRecords() async {
    // Keep pre-account books in their original device-local SharedPreferences
    // index. New books are stored only in the active UID's library directory.
    final records = books.where((book) => book.ownerUid == null).map((b) =>
        jsonEncode({'id': b.id, 'name': b.name, 'fileName': b.fileName,
          'type': b.isImageBook ? 'image' : 'json'})).toList();
    await _prefs.setStringList('book_records', records);

    final uid = _activeLibraryUid;
    if (uid != null) {
      final root = await _accountLibraryDirectory(uid);
      final accountRecords = books.where((book) => book.ownerUid == uid).map((book) => {
        'id': book.id,
        'name': book.name,
        'fileName': book.fileName,
        'type': book.isImageBook ? 'image' : 'json',
        'modifiedAt': book.modifiedAt,
      }).toList();
      final manifest = File('${root.path}/manifest.json');
      await manifest.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'books': accountRecords,
        'tombstones': _libraryTombstones,
      }), flush: true);
    }
  }
  @override
  void dispose() {
    wordStatesReady.dispose();
    wordStateRevision.dispose();
    libraryRevision.dispose();
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
