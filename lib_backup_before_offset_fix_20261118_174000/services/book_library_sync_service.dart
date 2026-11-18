import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/book_models.dart';
import 'book_store.dart';

enum LibrarySyncStatus { synced, pending, syncing, retrying, offline, failed }

/// Account-scoped library synchronization.
///
/// Synchronizes book metadata and content per book record. Image-book page
/// metadata and OCR vocabulary are included, but local image paths and image
/// bytes are deliberately excluded. Each book uses a server timestamp for
/// whole-book last-write-wins conflict resolution.
class BookLibrarySyncService {
  BookLibrarySyncService({
    required this.store,
    FirebaseDatabase? database,
  }) : _database = database ?? FirebaseDatabase.instance;

  final BookStore store;
  final FirebaseDatabase _database;

  final ValueNotifier<LibrarySyncStatus> status =
      ValueNotifier<LibrarySyncStatus>(LibrarySyncStatus.pending);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  StreamSubscription<DatabaseEvent>? _connectionSubscription;
  Timer? _debounce;
  Timer? _retry;
  Timer? _connectionListenerRestart;
  Timer? _recoveryTimer;
  AppLifecycleListener? _lifecycleListener;
  String? _uid;
  Future<void>? _activeSync;
  bool _connected = false;
  bool _queued = false;
  bool _disposed = false;
  int _generation = 0;
  int _retryAttempt = 0;
  int _connectionListenerRestartAttempt = 0;

  DatabaseReference _booksRef(String uid) =>
      _database.ref('users').child(uid).child('library').child('books');

  /// Firebase Realtime Database child keys cannot contain '.', '#', '$',
  /// '[', ']', '/', or control characters. Keep the original book ID in the
  /// record and use a deterministic URL-safe key only for the RTDB path.
  String _firebaseBookKey(String bookId) {
    if (bookId.isEmpty) {
      throw const FormatException('A library book has an empty ID.');
    }
    final encoded = base64Url.encode(utf8.encode(bookId)).replaceAll('=', '');
    return 'b_$encoded';
  }

  String? _decodeFirebaseBookKey(String key) {
    if (!key.startsWith('b_')) return null;
    try {
      final encoded = key.substring(2);
      final normalized = encoded.padRight(encoded.length + ((4 - encoded.length % 4) % 4), '=');
      return utf8.decode(base64Url.decode(normalized));
    } catch (_) {
      return null;
    }
  }

  DatabaseReference _bookRef(
    String uid,
    String bookId, {
    String? existingDatabaseKey,
  }) {
    final key = existingDatabaseKey ?? _firebaseBookKey(bookId);
    return _booksRef(uid).child(key);
  }

  bool _isPermanentDataError(Object error) {
    final message = error.toString().toLowerCase();
    return error is FormatException ||
        message.contains('invalid token in path') ||
        message.contains('invalid path') ||
        message.contains('uses a newer library schema') ||
        message.contains('malformed');
  }

  bool _isCurrent(String uid, int generation) =>
      !_disposed && _uid == uid && _generation == generation;

  void attachForUser(String uid) {
    if (_uid == uid && _connectionSubscription != null) return;
    _detach();
    _uid = uid;
    final generation = ++_generation;
    status.value = LibrarySyncStatus.pending;
    lastError.value = null;
    store.libraryRevision.addListener(_onLocalLibraryChanged);
    _lifecycleListener = AppLifecycleListener(
      onResume: () => unawaited(_probeFirebaseConnection(uid, generation)),
    );
    _attachConnectionListener(uid, generation);
    _ensureRecoveryTimer(uid, generation);
    unawaited(syncNow());
  }

  void _attachConnectionListener(String uid, int generation) {
    if (!_isCurrent(uid, generation) || _connectionSubscription != null) return;
    try {
      late final StreamSubscription<DatabaseEvent> subscription;
      subscription = _database.ref('.info/connected').onValue.listen(
        (event) {
          if (!_isCurrent(uid, generation)) return;
          final connected = event.snapshot.value == true;
          final wasConnected = _connected;
          _connected = connected;
          if (!connected) {
            status.value = LibrarySyncStatus.offline;
            _ensureRecoveryTimer(uid, generation);
            return;
          }
          _connectionListenerRestartAttempt = 0;
          _connectionListenerRestart?.cancel();
          _connectionListenerRestart = null;
          _recoveryTimer?.cancel();
          _recoveryTimer = null;
          if (!wasConnected) {
            _retry?.cancel();
            _retryAttempt = 0;
            // This request is immediate. If another sync is already active,
            // syncNow queues exactly one follow-up run.
            unawaited(syncNow());
          }
        },
        onError: (Object error) {
          if (!_isCurrent(uid, generation)) return;
          debugPrint('Library Firebase connection listener error: $error');
          if (identical(_connectionSubscription, subscription)) {
            _connectionSubscription = null;
          }
          _connected = false;
          status.value = LibrarySyncStatus.offline;
          _ensureRecoveryTimer(uid, generation);
          unawaited(subscription.cancel());
          _scheduleConnectionListenerRestart(uid, generation);
        },
        onDone: () {
          if (!_isCurrent(uid, generation)) return;
          debugPrint('Library Firebase connection listener ended; restarting.');
          if (identical(_connectionSubscription, subscription)) {
            _connectionSubscription = null;
          }
          _connected = false;
          status.value = LibrarySyncStatus.offline;
          _ensureRecoveryTimer(uid, generation);
          _scheduleConnectionListenerRestart(uid, generation);
        },
      );
      _connectionSubscription = subscription;
    } catch (error) {
      lastError.value = error.toString();
      _connected = false;
      status.value = LibrarySyncStatus.offline;
      _ensureRecoveryTimer(uid, generation);
      _scheduleConnectionListenerRestart(uid, generation);
    }
  }

  void _scheduleConnectionListenerRestart(String uid, int generation) {
    if (!_isCurrent(uid, generation)) return;
    _connectionListenerRestart?.cancel();
    const delays = [2, 5, 15, 30, 60];
    final seconds = delays[
      _connectionListenerRestartAttempt.clamp(0, delays.length - 1).toInt()
    ];
    _connectionListenerRestartAttempt++;
    _connectionListenerRestart = Timer(Duration(seconds: seconds), () {
      if (!_isCurrent(uid, generation) || _connectionSubscription != null) return;
      _attachConnectionListener(uid, generation);
    });
  }

  void _detach() {
    _generation++;
    _debounce?.cancel();
    _retry?.cancel();
    _connectionListenerRestart?.cancel();
    _connectionListenerRestart = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    unawaited(_connectionSubscription?.cancel());
    _connectionSubscription = null;
    store.libraryRevision.removeListener(_onLocalLibraryChanged);
    _uid = null;
    _connected = false;
    _queued = false;
  }

  void _ensureRecoveryTimer(String uid, int generation) {
    if (!_isCurrent(uid, generation) || _connected || _recoveryTimer != null) return;
    _recoveryTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_probeFirebaseConnection(uid, generation));
    });
  }

  Future<void> _probeFirebaseConnection(String uid, int generation) async {
    if (!_isCurrent(uid, generation)) return;
    try {
      final snapshot = await _database.ref('.info/connected')
          .get()
          .timeout(const Duration(seconds: 5));
      if (!_isCurrent(uid, generation)) return;
      final connected = snapshot.value == true;
      final wasConnected = _connected;
      _connected = connected;
      if (connected) {
        _recoveryTimer?.cancel();
        _recoveryTimer = null;
        _retry?.cancel();
        _retryAttempt = 0;
        if (_connectionSubscription == null) {
          _connectionListenerRestart?.cancel();
          _connectionListenerRestart = null;
          _attachConnectionListener(uid, generation);
        }
        if (!wasConnected || status.value != LibrarySyncStatus.synced) {
          unawaited(syncNow());
        }
      } else {
        status.value = LibrarySyncStatus.offline;
        _ensureRecoveryTimer(uid, generation);
        if (_connectionSubscription == null) {
          _scheduleConnectionListenerRestart(uid, generation);
        }
      }
    } catch (error) {
      if (!_isCurrent(uid, generation)) return;
      lastError.value = 'Could not verify Firebase connectivity: $error';
      status.value = LibrarySyncStatus.offline;
      _ensureRecoveryTimer(uid, generation);
      if (_connectionSubscription == null) {
        _scheduleConnectionListenerRestart(uid, generation);
      }
    }
  }

  void _onLocalLibraryChanged() {
    if (_uid == null) return;
    status.value = LibrarySyncStatus.pending;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1600), () {
      unawaited(syncNow());
    });
  }

  Future<void> syncNow({bool userInitiated = false}) {
    final uid = _uid;
    if (uid == null || _disposed) return Future<void>.value();
    if (!_connected) {
      status.value = LibrarySyncStatus.offline;
      return Future<void>.value();
    }
    _debounce?.cancel();
    _retry?.cancel();
    if (userInitiated) {
      _retryAttempt = 0;
      lastError.value = null;
    }
    final active = _activeSync;
    if (active != null) {
      _queued = true;
      return active;
    }
    final generation = _generation;
    final future = _runSync(uid, generation);
    _activeSync = future;
    return future.whenComplete(() {
      if (identical(_activeSync, future)) _activeSync = null;
      if (_isCurrent(uid, generation) && _queued) {
        _queued = false;
        scheduleMicrotask(() => unawaited(syncNow()));
      }
    });
  }

  Future<void> _runSync(String uid, int generation) async {
    if (!_isCurrent(uid, generation) || !_connected) return;
    // Keep the previous error visible while an automatic retry is pending.
    // This prevents the Account & Sync panel from flashing Failed/Syncing on
    // every backoff cycle. The error clears only after a verified success or
    // an explicit fresh user request.
    status.value = lastError.value != null
        ? LibrarySyncStatus.retrying
        : LibrarySyncStatus.syncing;
    final startingLibraryRevision = store.libraryRevision.value;
    try {
      final offsetSnapshot = await _database.ref('.info/serverTimeOffset').get().timeout(const Duration(seconds: 15));
      if (!_isCurrent(uid, generation) || !_connected) return;
      final offset = (offsetSnapshot.value as num?)?.toInt() ?? 0;
      store.setLibraryServerTimeOffsetMs(offset);

      final rootSnapshot = await _booksRef(uid).get().timeout(const Duration(seconds: 30));
      if (!_isCurrent(uid, generation) || !_connected) return;
      final cloudBooks = <String, _CloudBookRecord>{};
      final rootValue = rootSnapshot.value;
      if (rootValue is Map) {
        for (final entry in rootValue.entries) {
          if (entry.value is! Map) continue;
          final databaseKey = entry.key.toString();
          final record = Map<String, dynamic>.from(entry.value as Map);
          final rawSchemaVersion = record['schemaVersion'];
          if (rawSchemaVersion != null && rawSchemaVersion is! num) {
            throw FormatException('Book at database key "$databaseKey" has an invalid schema version.');
          }
          final schemaVersion = (rawSchemaVersion as num?)?.toInt() ?? 1;
          if (schemaVersion > 1) {
            throw FormatException(
              'Book at database key "$databaseKey" uses a newer library schema ($schemaVersion). '
              'This app will not overwrite data it cannot understand.',
            );
          }
          final updatedAt = record['updatedAt'];
          if (updatedAt is! num || updatedAt <= 0) {
            throw FormatException(
              'Book at database key "$databaseKey" has no valid server timestamp. '
              'The local copy will be preserved.',
            );
          }
          // Current releases wrote the original ID as the Firebase child key.
          // New releases use an encoded key. Prefer the explicit ID in the
          // record and retain the actual database key for safe legacy updates.
          final id = (record['id'] ?? _decodeFirebaseBookKey(databaseKey) ?? databaseKey).toString();
          if (id.isEmpty) {
            throw FormatException('Book at database key "$databaseKey" has no ID.');
          }
          final candidate = _CloudBookRecord(
            databaseKey: databaseKey,
            data: record,
            updatedAt: updatedAt.toInt(),
          );
          final previous = cloudBooks[id];
          if (previous == null || candidate.updatedAt > previous.updatedAt) {
            cloudBooks[id] = candidate;
          } else if (candidate.updatedAt == previous.updatedAt &&
              candidate.databaseKey == _firebaseBookKey(id)) {
            // On equal timestamps, prefer the canonical encoded location.
            cloudBooks[id] = candidate;
          }
        }
      }

      final localBooks = store.accountBooks(uid);
      final localById = {for (final book in localBooks) book.id: book};
      final tombstones = store.accountLibraryTombstones;

      // Resolve local deletion tombstones first so an older cloud copy cannot
      // resurrect a book that the user explicitly removed.
      for (final deletion in tombstones.entries) {
        if (!_isCurrent(uid, generation) || !_connected) return;
        final cloudEntry = cloudBooks[deletion.key];
        final cloud = cloudEntry?.data;
        final cloudTime = cloudEntry?.updatedAt ?? 0;
        if (cloud == null || deletion.value > cloudTime) {
          final databaseKey = cloudEntry?.databaseKey ?? _firebaseBookKey(deletion.key);
          debugPrint('Library deletion: uid=$uid bookId=${deletion.key} databaseKey=$databaseKey');
          final ref = _bookRef(
            uid,
            deletion.key,
            existingDatabaseKey: databaseKey,
          );
          dynamic verifiedRecord;
          try {
            await ref.set({
              'schemaVersion': 1,
              'id': deletion.key,
              'deleted': true,
              'updatedAt': ServerValue.timestamp,
            }).timeout(const Duration(seconds: 60));
            final verify = await ref.get().timeout(const Duration(seconds: 30));
            verifiedRecord = verify.value;
          } catch (error) {
            throw StateError(
              'Deletion sync failed for book ID "${deletion.key}" '
              'at Firebase key "$databaseKey": $error',
            );
          }
          final serverTime = verifiedRecord is Map
              ? ((verifiedRecord['updatedAt'] as num?)?.toInt() ?? 0)
              : 0;
          if (verifiedRecord is Map && verifiedRecord['deleted'] == true && serverTime > 0) {
            // Keep the in-memory cloud index in sync with this just-written
            // tombstone. Otherwise the later download pass could process the
            // stale pre-delete snapshot and resurrect the deleted book.
            cloudBooks[deletion.key] = _CloudBookRecord(
              databaseKey: databaseKey,
              data: Map<String, dynamic>.from(verifiedRecord),
              updatedAt: serverTime,
            );
            await store.acknowledgeAccountBookDeleted(uid, deletion.key);
          } else {
            throw StateError('Firebase did not confirm deletion of book ${deletion.key}.');
          }
        } else if (cloud['deleted'] == true) {
          await store.acknowledgeAccountBookDeleted(uid, deletion.key);
        } else {
          final remote = Map<String, dynamic>.from(cloud)..['id'] = deletion.key;
          await store.applyRemoteAccountBook(uid, remote, serverUpdatedAt: cloudTime);
          // The newer cloud copy wins over this older local deletion. Add it
          // to the in-memory pass index so the download phase does not apply
          // the same record twice.
          for (final restored in store.accountBooks(uid)) {
            if (restored.id == deletion.key) {
              localById[deletion.key] = restored;
              break;
            }
          }
          await store.acknowledgeAccountBookDeleted(uid, deletion.key);
        }
      }

      // Upload local additions/edits or download newer remote records.
      for (final book in localById.values.toList(growable: false)) {
        if (!_isCurrent(uid, generation) || !_connected) return;
        if (store.accountLibraryTombstones.containsKey(book.id)) continue;
        final cloudEntry = cloudBooks[book.id];
        final cloud = cloudEntry?.data;
        if (cloud == null) {
          await _uploadBook(uid, book, generation);
          continue;
        }
        final existingCloud = cloudEntry!;
        final cloudTime = existingCloud.updatedAt;
        if (cloud['deleted'] == true) {
          if (book.modifiedAt > cloudTime) {
            await _uploadBook(uid, book, generation, existingDatabaseKey: existingCloud.databaseKey);
          } else {
            await store.removeRemoteAccountBook(uid, book.id);
          }
        } else if (cloudTime > book.modifiedAt || cloudTime == book.modifiedAt) {
          final remote = Map<String, dynamic>.from(cloud)..['id'] = book.id;
          await store.applyRemoteAccountBook(uid, remote, serverUpdatedAt: cloudTime);
        } else {
          await _uploadBook(
            uid,
            book,
            generation,
            existingDatabaseKey: existingCloud.databaseKey,
          );
        }
      }

      // Bring down cloud books that do not yet have a local copy.
      for (final entry in cloudBooks.entries) {
        if (!_isCurrent(uid, generation) || !_connected) return;
        final bookId = entry.key;
        final record = entry.value.data;
        if (localById.containsKey(bookId) ||
            store.accountLibraryTombstones.containsKey(bookId) ||
            record['deleted'] == true) {
          continue;
        }
        final remote = Map<String, dynamic>.from(record)..['id'] = bookId;
        await store.applyRemoteAccountBook(
          uid,
          remote,
          serverUpdatedAt: entry.value.updatedAt,
        );
      }

      if (!_isCurrent(uid, generation) || !_connected) return;
      // A book/page may have changed while this snapshot was being uploaded.
      // Never report Synced for an older revision: queue one fresh full pass.
      if (store.libraryRevision.value != startingLibraryRevision) {
        status.value = LibrarySyncStatus.pending;
        _queued = true;
        return;
      }
      _retryAttempt = 0;
      lastError.value = null;
      status.value = LibrarySyncStatus.synced;
    } catch (error, stackTrace) {
      if (!_isCurrent(uid, generation)) return;
      lastError.value = _describeError(error);
      debugPrint('Library synchronization failed for UID $uid: $error\n$stackTrace');
      if (_isPermanentDataError(error)) {
        _retry?.cancel();
        status.value = LibrarySyncStatus.failed;
      } else {
        status.value = _connected ? LibrarySyncStatus.retrying : LibrarySyncStatus.offline;
        _scheduleRetry(uid, generation);
      }
    }
  }

  String _describeError(Object error) {
    final message = error.toString();
    if (message.toLowerCase().contains('invalid token in path')) {
      return 'Firebase rejected a library database key. New writes now use encoded keys. Details: $message';
    }
    return message;
  }

  Future<void> _uploadBook(
    String uid,
    BookData book,
    int generation, {
    String? existingDatabaseKey,
  }) async {
    final expectedModifiedAt = book.modifiedAt;
    final payload = await store.exportAccountBook(book);
    if (!_isCurrent(uid, generation) || !_connected) return;
    final databaseKey = existingDatabaseKey ?? _firebaseBookKey(book.id);
    debugPrint('Library upload: uid=$uid bookId=${book.id} databaseKey=$databaseKey');
    final ref = _bookRef(uid, book.id, existingDatabaseKey: databaseKey);
    try {
      await ref.set({...payload, 'deleted': false, 'updatedAt': ServerValue.timestamp})
          .timeout(const Duration(seconds: 60));
    } catch (error) {
      throw StateError(
        'Upload failed for book ID "${book.id}" at Firebase key "$databaseKey": $error',
      );
    }
    if (!_isCurrent(uid, generation) || !_connected) return;
    final verify = await ref.get().timeout(const Duration(seconds: 30));
    if (!_isCurrent(uid, generation) || !_connected) return;
    final value = verify.value;
    if (value is! Map || value['deleted'] == true || value['id'] != book.id ||
        ((value['schemaVersion'] as num?)?.toInt() ?? 1) != 1) {
      throw StateError(
        'Firebase did not confirm book ID "${book.id}" at database key "$databaseKey".',
      );
    }
    final payloadMatches = payload.entries.every(
      (entry) => value[entry.key] == entry.value,
    );
    if (!payloadMatches) {
      throw StateError('Firebase book content does not match the local snapshot.');
    }
    final serverTime = (value['updatedAt'] as num?)?.toInt() ?? 0;
    if (serverTime <= 0) {
      throw StateError('Firebase book snapshot has no server timestamp.');
    }
    await store.setLibraryServerModifiedAt(
      uid,
      book.id,
      expectedModifiedAt,
      serverTime,
    );
  }

  void _scheduleRetry(String uid, int generation) {
    if (!_isCurrent(uid, generation) || !_connected) return;
    status.value = LibrarySyncStatus.retrying;
    _retry?.cancel();
    const delays = [2, 5, 15, 30, 60];
    final seconds = delays[_retryAttempt.clamp(0, delays.length - 1).toInt()];
    _retryAttempt++;
    _retry = Timer(Duration(seconds: seconds), () {
      if (_isCurrent(uid, generation)) unawaited(syncNow());
    });
  }

  Future<void> stop() async {
    _detach();
    final active = _activeSync;
    if (active != null) {
      try {
        await active;
      } catch (_) {}
    }
    _activeSync = null;
    status.value = LibrarySyncStatus.pending;
  }

  void dispose() {
    _disposed = true;
    _detach();
    status.dispose();
    lastError.dispose();
  }
}


class _CloudBookRecord {
  const _CloudBookRecord({
    required this.databaseKey,
    required this.data,
    required this.updatedAt,
  });

  final String databaseKey;
  final Map<String, dynamic> data;
  final int updatedAt;
}
