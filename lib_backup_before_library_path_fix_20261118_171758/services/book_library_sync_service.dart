import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/book_models.dart';
import 'book_store.dart';

enum LibrarySyncStatus { synced, pending, syncing, offline, failed }

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
      _database.ref('users/$uid/library/books');

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

  Future<void> syncNow() {
    final uid = _uid;
    if (uid == null || _disposed) return Future<void>.value();
    if (!_connected) {
      status.value = LibrarySyncStatus.offline;
      return Future<void>.value();
    }
    _debounce?.cancel();
    _retry?.cancel();
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
    status.value = LibrarySyncStatus.syncing;
    lastError.value = null;
    try {
      final offsetSnapshot = await _database.ref('.info/serverTimeOffset').get().timeout(const Duration(seconds: 15));
      if (!_isCurrent(uid, generation) || !_connected) return;
      final offset = (offsetSnapshot.value as num?)?.toInt() ?? 0;
      store.setLibraryServerTimeOffsetMs(offset);

      final rootSnapshot = await _booksRef(uid).get().timeout(const Duration(seconds: 30));
      if (!_isCurrent(uid, generation) || !_connected) return;
      final cloudBooks = <String, Map<String, dynamic>>{};
      final rootValue = rootSnapshot.value;
      if (rootValue is Map) {
        for (final entry in rootValue.entries) {
          if (entry.value is Map) {
            final record = Map<String, dynamic>.from(entry.value as Map);
            final rawSchemaVersion = record['schemaVersion'];
            if (rawSchemaVersion != null && rawSchemaVersion is! num) {
              throw FormatException('Book ${entry.key} has an invalid schema version.');
            }
            final schemaVersion = (rawSchemaVersion as num?)?.toInt() ?? 1;
            if (schemaVersion > 1) {
              throw FormatException(
                'Book ${entry.key} uses a newer library schema ($schemaVersion). '
                'This app will not overwrite data it cannot understand.',
              );
            }
            final updatedAt = record['updatedAt'];
            if (updatedAt is! num || updatedAt <= 0) {
              throw FormatException(
                'Book ${entry.key} has no valid server timestamp. '
                'The local copy will be preserved.',
              );
            }
            cloudBooks[entry.key.toString()] = record;
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
        final cloud = cloudBooks[deletion.key];
        final cloudTime = (cloud?['updatedAt'] as num?)?.toInt() ?? 0;
        if (cloud == null || deletion.value > cloudTime) {
          final ref = _booksRef(uid).child(deletion.key);
          await ref.set({
            'schemaVersion': 1,
            'id': deletion.key,
            'deleted': true,
            'updatedAt': ServerValue.timestamp,
          }).timeout(const Duration(seconds: 60));
          final verify = await ref.get().timeout(const Duration(seconds: 30));
          final verifiedRecord = verify.value;
          final serverTime = ((verify.value as Map?)?['updatedAt'] as num?)?.toInt() ?? 0;
          if (verifiedRecord is Map && verifiedRecord['deleted'] == true && serverTime > 0) {
            await store.acknowledgeAccountBookDeleted(uid, deletion.key);
          } else {
            throw StateError('Firebase did not confirm deletion of book ${deletion.key}.');
          }
        } else if (cloud['deleted'] == true) {
          await store.acknowledgeAccountBookDeleted(uid, deletion.key);
        } else {
          final remote = Map<String, dynamic>.from(cloud)..['id'] = deletion.key;
          await store.applyRemoteAccountBook(uid, remote, serverUpdatedAt: cloudTime);
          await store.acknowledgeAccountBookDeleted(uid, deletion.key);
        }
      }

      // Upload local additions/edits or download newer remote records.
      for (final book in localById.values.toList(growable: false)) {
        if (!_isCurrent(uid, generation) || !_connected) return;
        if (store.accountLibraryTombstones.containsKey(book.id)) continue;
        final cloud = cloudBooks[book.id];
        if (cloud == null) {
          await _uploadBook(uid, book, generation);
          continue;
        }
        final cloudTime = (cloud['updatedAt'] as num?)?.toInt() ?? 0;
        if (cloud['deleted'] == true) {
          if (book.modifiedAt > cloudTime) {
            await _uploadBook(uid, book, generation);
          } else {
            await store.removeRemoteAccountBook(uid, book.id);
          }
        } else if (cloudTime > book.modifiedAt || cloudTime == book.modifiedAt) {
          final remote = Map<String, dynamic>.from(cloud)..['id'] = book.id;
          await store.applyRemoteAccountBook(uid, remote, serverUpdatedAt: cloudTime);
        } else {
          await _uploadBook(uid, book, generation);
        }
      }

      // Bring down cloud books that do not yet have a local copy.
      for (final entry in cloudBooks.entries) {
        if (!_isCurrent(uid, generation) || !_connected) return;
        if (localById.containsKey(entry.key) ||
            store.accountLibraryTombstones.containsKey(entry.key) ||
            entry.value['deleted'] == true) {
          continue;
        }
        final remote = Map<String, dynamic>.from(entry.value)..['id'] = entry.key;
        final cloudTime = (entry.value['updatedAt'] as num?)?.toInt() ?? 0;
        await store.applyRemoteAccountBook(uid, remote, serverUpdatedAt: cloudTime);
      }

      if (!_isCurrent(uid, generation) || !_connected) return;
      _retryAttempt = 0;
      status.value = LibrarySyncStatus.synced;
    } catch (error) {
      if (!_isCurrent(uid, generation)) return;
      lastError.value = error.toString();
      status.value = _connected ? LibrarySyncStatus.failed : LibrarySyncStatus.offline;
      _scheduleRetry(uid, generation);
    }
  }

  Future<void> _uploadBook(String uid, BookData book, int generation) async {
    final expectedModifiedAt = book.modifiedAt;
    final payload = await store.exportAccountBook(book);
    if (!_isCurrent(uid, generation) || !_connected) return;
    final ref = _booksRef(uid).child(book.id);
    await ref.set({...payload, 'deleted': false, 'updatedAt': ServerValue.timestamp})
        .timeout(const Duration(seconds: 60));
    if (!_isCurrent(uid, generation) || !_connected) return;
    final verify = await ref.get().timeout(const Duration(seconds: 30));
    if (!_isCurrent(uid, generation) || !_connected) return;
    final value = verify.value;
    if (value is! Map || value['deleted'] == true || value['id'] != book.id ||
        ((value['schemaVersion'] as num?)?.toInt() ?? 1) != 1) {
      throw StateError('Firebase did not confirm the uploaded book snapshot.');
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
