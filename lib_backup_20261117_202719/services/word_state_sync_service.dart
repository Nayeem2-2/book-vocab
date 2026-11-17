import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_store.dart';

enum WordSyncStatus { synced, pending, syncing, failed }

/// Synchronizes only the global Known / Show Again word-state snapshot.
/// Books, pages, images and dictionary data are deliberately never uploaded.
class WordStateSyncService {
  WordStateSyncService({required this.store, FirebaseDatabase? database})
      : _database = database ?? FirebaseDatabase.instance;

  final BookStore store;
  final FirebaseDatabase _database;
  final ValueNotifier<WordSyncStatus> status =
      ValueNotifier<WordSyncStatus>(WordSyncStatus.pending);

  static const _localTimestampKey = 'word_states_last_modified_at';
  StreamSubscription<DatabaseEvent>? _connectionSubscription;
  Timer? _debounce;
  String? _uid;
  Future<void>? _activeSync;
  bool _disposed = false;

  DatabaseReference get _userRef =>
      _database.ref('users/$_uid/wordStates');

  // The listener is removed when the account changes or the gate is closed.
  void attachForUser(String uid) {
    if (_uid == uid && _listenerAttached) return;
    _detachListener();
    _uid = uid;
    store.wordStateRevision.addListener(_onLocalRevision);
    _listenerAttached = true;
    _connectionSubscription = _database.ref('.info/connected').onValue.listen(
      (event) {
        final connected = event.snapshot.value == true;
        if (connected && _uid == uid && (status.value == WordSyncStatus.pending ||
            status.value == WordSyncStatus.failed)) {
          unawaited(syncNow());
        }
      },
      onError: (Object error) {
        debugPrint('Firebase connection monitor error: $error');
      },
    );
  }

  bool _listenerAttached = false;
  bool _applyingRemote = false;

  void _onLocalRevision() {
    if (_uid == null || _disposed || _applyingRemote) return;
    _recordLocalChange();
  }

  void _recordLocalChange() {
    if (_uid == null || _disposed) return;
    status.value = WordSyncStatus.pending;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1600), () {
      unawaited(syncNow());
    });
  }

  Future<void> syncNow() {
    if (_uid == null || _disposed) return Future<void>.value();
    final active = _activeSync;
    if (active != null) return active;
    _debounce?.cancel();
    late final Future<void> tracked;
    tracked = _performSync().whenComplete(() {
      if (identical(_activeSync, tracked)) _activeSync = null;
    });
    _activeSync = tracked;
    return tracked;
  }

  Future<void> _performSync() async {
    status.value = WordSyncStatus.syncing;
    final uid = _uid!;
    try {
      final prefs = await SharedPreferences.getInstance();
      final localTimestamp = prefs.getInt(_localTimestampKey) ?? 0;
      var startingRevision = store.wordStateRevision.value;
      final snapshot = await _userRef.get().timeout(const Duration(seconds: 15));
      if (store.wordStateRevision.value != startingRevision) {
        _queueRetry();
        return;
      }

      if (!snapshot.exists || snapshot.value == null) {
        // First sign-in for this account: seed the cloud from existing local data.
        await _uploadSnapshot(uid, startingRevision).timeout(
          const Duration(seconds: 20),
        );
      } else {
        final cloud = _asMap(snapshot.value);
        if (cloud['known'] is! List || cloud['showAgain'] is! List) {
          throw const FormatException('Cloud word-state lists are missing or invalid.');
        }
        final cloudTimestamp = _asInt(cloud['updatedAt']);
        if (cloudTimestamp == null) {
          throw const FormatException('Cloud word-state timestamp is missing or invalid.');
        }
        if (localTimestamp == 0 || cloudTimestamp >= localTimestamp) {
          // Back up local data before any destructive replacement.
          await store.backupKnownWords();
          if (store.wordStateRevision.value != startingRevision) {
            _queueRetry();
            return;
          }
          final revisionBeforeRemoteApply = store.wordStateRevision.value;
          _applyingRemote = true;
          try {
            await store.replaceWordStates(
              known: _asStringList(cloud['known']),
              showAgain: _asStringList(cloud['showAgain']),
            );
          } finally {
            _applyingRemote = false;
          }
          final expectedRemoteRevision = revisionBeforeRemoteApply + 1;
          if (store.wordStateRevision.value != expectedRemoteRevision) {
            // A user changed a word while the remote snapshot was being saved.
            // Keep that edit newer than the cloud snapshot and upload it next.
            await prefs.setInt(
              _localTimestampKey,
              DateTime.now().millisecondsSinceEpoch > cloudTimestamp
                  ? DateTime.now().millisecondsSinceEpoch
                  : cloudTimestamp + 1,
            );
            _queueRetry();
            return;
          }
          await prefs.setInt(_localTimestampKey, cloudTimestamp);
          if (store.wordStateRevision.value != expectedRemoteRevision) {
            await prefs.setInt(
              _localTimestampKey,
              DateTime.now().millisecondsSinceEpoch > cloudTimestamp
                  ? DateTime.now().millisecondsSinceEpoch
                  : cloudTimestamp + 1,
            );
            _queueRetry();
            return;
          }
          startingRevision = expectedRemoteRevision;
          status.value = WordSyncStatus.synced;
        } else {
          await _uploadSnapshot(uid, startingRevision).timeout(
            const Duration(seconds: 20),
          );
        }
      }

      // A word-state edit made while the network operation was running must
      // not be marked as synchronized by the older snapshot.
      if (store.wordStateRevision.value != startingRevision) {
        _queueRetry();
      } else if (status.value != WordSyncStatus.synced) {
        status.value = WordSyncStatus.synced;
      }
    } catch (error) {
      debugPrint('Word-state synchronization failed: $error');
      status.value = WordSyncStatus.failed;
    }
  }

  void _queueRetry() {
    status.value = WordSyncStatus.pending;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(syncNow());
    });
  }

  Future<void> _uploadSnapshot(String uid, int revision) async {
    final snapshot = store.wordStateSnapshot();
    await _database.ref('users/$uid/wordStates').set({
      'known': snapshot['known'],
      'showAgain': snapshot['showAgain'],
      'updatedAt': ServerValue.timestamp,
    });
    final written = await _database
        .ref('users/$uid/wordStates/updatedAt')
        .get()
        .timeout(const Duration(seconds: 10));
    final timestamp = _asInt(written.value);
    if (timestamp == null) {
      throw const FormatException('Firebase did not return the saved timestamp.');
    }
    if (store.wordStateRevision.value == revision) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_localTimestampKey, timestamp);
      status.value = WordSyncStatus.synced;
    }
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const FormatException('Cloud word-state data has an invalid format.');
  }

  int? _asInt(Object? value) => value is num ? value.toInt() : int.tryParse('$value');

  List<String> _asStringList(Object? value) {
    if (value == null) return <String>[];
    if (value is! List) {
      throw const FormatException('Cloud word-state list has an invalid format.');
    }
    return value.map((item) => item.toString()).toList();
  }

  Future<void> stop() async {
    _debounce?.cancel();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _detachListener();
    _uid = null;
  }

  void _detachListener() {
    if (_listenerAttached) {
      store.wordStateRevision.removeListener(_onLocalRevision);
      _listenerAttached = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    status.dispose();
  }
}
