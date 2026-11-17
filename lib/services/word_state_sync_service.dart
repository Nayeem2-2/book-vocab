import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_store.dart';

enum WordSyncStatus { synced, pending, syncing, failed }

/// Synchronizes one complete Known / Show Again snapshot for the active UID.
/// Books, pages, images, OCR data and dictionary data are never uploaded.
class WordStateSyncService {
  WordStateSyncService({required this.store, FirebaseDatabase? database})
      : _database = database ?? FirebaseDatabase.instance;

  final BookStore store;
  final FirebaseDatabase _database;

  final ValueNotifier<WordSyncStatus> status =
      ValueNotifier<WordSyncStatus>(WordSyncStatus.pending);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  static const int _schemaVersion = 2;
  static const String _serverOffsetKey = 'word_states_server_time_offset_ms';

  StreamSubscription<DatabaseEvent>? _connectionSubscription;
  Timer? _debounce;
  Timer? _retryTimer;
  String? _uid;
  Future<void>? _activeSync;
  bool _disposed = false;
  bool _listenerAttached = false;
  bool _applyingRemote = false;
  bool _firebaseConnected = false;
  int _accountGeneration = 0;
  int _retryAttempt = 0;

  DatabaseReference _wordStatesRef(String uid) =>
      _database.ref('users/$uid/wordStates');

  String _localTimestampKey(String uid) =>
      'word_states_last_modified_at_${BookStore.accountStorageKey(uid)}';

  String _timestampAdjustedKey(String uid) =>
      'word_states_timestamp_server_adjusted_${BookStore.accountStorageKey(uid)}';

  /// Starts local-change and Firebase connectivity monitoring for one UID.
  void attachForUser(String uid) {
    if (_uid == uid && _listenerAttached) return;

    _accountGeneration++;
    _debounce?.cancel();
    _retryTimer?.cancel();
    unawaited(_connectionSubscription?.cancel());
    _connectionSubscription = null;
    _detachListener();
    _activeSync = null;
    _uid = uid;
    _firebaseConnected = false;
    _retryAttempt = 0;
    lastError.value = null;
    status.value = WordSyncStatus.pending;

    store.wordStateRevision.addListener(_onLocalRevision);
    _listenerAttached = true;
    final generation = _accountGeneration;
    _connectionSubscription = _database.ref('.info/connected').onValue.listen(
      (event) {
        if (!_isCurrent(uid, generation)) return;
        final connected = event.snapshot.value == true;
        _firebaseConnected = connected;
        if (connected) {
          // Connectivity restoration should bypass the retry backoff.
          _retryTimer?.cancel();
          _retryAttempt = 0;
          if (status.value != WordSyncStatus.syncing) {
            unawaited(syncNow());
          }
        } else {
          // A returning account may continue with its own previously synced
          // cache while offline. A brand-new account with no cache stays
          // read-only until its first successful cloud reconciliation.
          store.markCachedWordStatesReadyOffline();
          if (status.value != WordSyncStatus.syncing) {
            status.value = WordSyncStatus.pending;
            lastError.value = store.hasLocalAccountCache
                ? 'Offline — using this account’s saved progress.'
                : 'Waiting for the first connection to load this account’s progress.';
          }
        }
      },
      onError: (Object error) {
        if (_isCurrent(uid, generation)) {
          debugPrint('Firebase connection monitor error: $error');
        }
      },
    );
  }

  void _onLocalRevision() {
    if (_uid == null || _disposed || _applyingRemote) return;
    _recordLocalChange();
  }

  void _recordLocalChange() {
    final uid = _uid;
    if (uid == null || _disposed) return;
    status.value = WordSyncStatus.pending;
    lastError.value = _firebaseConnected
        ? null
        : 'Changes are saved on this device and waiting for internet.';
    _retryTimer?.cancel();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1600), () {
      unawaited(syncNow());
    });
  }

  bool _isCurrent(String uid, int generation) =>
      !_disposed &&
      _uid == uid &&
      _accountGeneration == generation &&
      store.activeAccountUid == uid;

  /// Attempts immediately when Firebase is connected. Offline calls leave the
  /// local snapshot untouched; the .info/connected listener retries later.
  Future<void> syncNow() {
    final uid = _uid;
    if (uid == null || _disposed) return Future<void>.value();
    final active = _activeSync;
    if (active != null) return active;

    _debounce?.cancel();
    if (!_firebaseConnected) {
      status.value = WordSyncStatus.pending;
      lastError.value = 'Waiting for an internet connection. Local data is safe.';
      return Future<void>.value();
    }

    final generation = _accountGeneration;
    late final Future<void> tracked;
    tracked = _performSync(uid, generation).whenComplete(() {
      if (identical(_activeSync, tracked)) _activeSync = null;
    });
    _activeSync = tracked;
    return tracked;
  }

  Future<void> _performSync(String uid, int generation) async {
    if (!_isCurrent(uid, generation)) return;
    status.value = WordSyncStatus.syncing;
    lastError.value = null;

    try {
      // Sync can be requested manually immediately after a UI change. Wait
      // for that change's timestamp and account file to finish persisting.
      await store.flushPendingWordStateWrites();
      if (!_isCurrent(uid, generation)) return;

      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrent(uid, generation)) return;

      // Refresh Firebase's clock offset. A previously stored offset remains a
      // safe fallback if this one lookup fails.
      var serverOffset = prefs.getInt(_serverOffsetKey) ?? 0;
      var receivedFreshOffset = false;
      try {
        final offsetSnapshot = await _database
            .ref('.info/serverTimeOffset')
            .get()
            .timeout(const Duration(seconds: 5));
        final value = offsetSnapshot.value;
        if (value is num) {
          serverOffset = value.toInt();
          receivedFreshOffset = true;
          await prefs.setInt(_serverOffsetKey, serverOffset);
        }
      } catch (error) {
        debugPrint('Could not refresh Firebase server-time offset: $error');
      }
      store.setServerTimeOffsetMs(serverOffset);

      final timestampKey = _localTimestampKey(uid);
      final adjustedKey = _timestampAdjustedKey(uid);
      var localTimestamp = prefs.getInt(timestampKey) ?? 0;
      final timestampWasAdjusted = prefs.getBool(adjustedKey) ?? false;
      if (localTimestamp > 0 && !timestampWasAdjusted && receivedFreshOffset) {
        localTimestamp += serverOffset;
        await prefs.setInt(timestampKey, localTimestamp);
        await prefs.setBool(adjustedKey, true);
      } else if (receivedFreshOffset && !timestampWasAdjusted) {
        await prefs.setBool(adjustedKey, true);
      }

      // Obtain a stable local snapshot boundary. If a word changes while its
      // timestamp/file is being flushed, repeat; if it changes after this
      // boundary, the revision comparison below detects the race.
      var startingRevision = store.wordStateRevision.value;
      while (true) {
        final candidateRevision = store.wordStateRevision.value;
        await store.flushPendingWordStateWrites();
        if (store.wordStateRevision.value == candidateRevision) {
          startingRevision = candidateRevision;
          break;
        }
      }
      localTimestamp = prefs.getInt(timestampKey) ?? localTimestamp;
      final cloudSnapshot = await _wordStatesRef(uid)
          .get()
          .timeout(const Duration(seconds: 15));
      if (!_isCurrent(uid, generation)) return;

      final cloud = cloudSnapshot.exists && cloudSnapshot.value != null
          ? _tryParseCloudSnapshot(cloudSnapshot.value)
          : null;

      // If the user changed a word while the cloud read was in flight, do not
      // apply a snapshot based on an older local revision. If the cloud read
      // was valid, retain it as the rollback baseline before retrying so a
      // later logout cannot restore an older cloud snapshot.
      if (store.wordStateRevision.value != startingRevision) {
        if (cloud != null) {
          await store.markWordStateSnapshotAsSynced(
            uid: uid,
            known: cloud.known,
            showAgain: cloud.showAgain,
            updatedAt: cloud.updatedAt,
          );
          final localNow = _serverNowMilliseconds(serverOffset);
          if (localTimestamp <= cloud.updatedAt) {
            localTimestamp = localNow > cloud.updatedAt
                ? localNow
                : cloud.updatedAt + 1;
            await prefs.setInt(timestampKey, localTimestamp);
            await prefs.setBool(adjustedKey, true);
          }
        }
        _queueRevisionRetry(uid, generation);
        return;
      }

      if (!cloudSnapshot.exists || cloudSnapshot.value == null) {
        // This UID has no cloud snapshot yet. Its own local cache (if any) is
        // the only valid seed; another account's data is never consulted.
        await _uploadSnapshot(uid, generation, prefs,
            serverOffset, timestampKey, adjustedKey);
        return;
      }

      if (cloud == null) {
        // Timestamp-only/incomplete records are not empty snapshots. Repair
        // them using this UID's local cache, never the legacy global file.
        debugPrint('Incomplete cloud word-state snapshot for $uid; repairing from this account\'s local cache.');
        await _uploadSnapshot(uid, generation, prefs,
            serverOffset, timestampKey, adjustedKey);
        return;
      }

      // If a local cache differs from this UID's last successful snapshot
      // but its timestamp metadata was lost, do not silently let the cloud
      // overwrite those pending changes. Assign a conservative server-based
      // timestamp so the standard LWW comparison can proceed safely.
      final hasLocalPendingChanges =
          await store.hasUnsyncedWordStateChanges();
      if (hasLocalPendingChanges && localTimestamp <= 0) {
        final localNow = _serverNowMilliseconds(serverOffset);
        localTimestamp = localNow > cloud.updatedAt
            ? localNow
            : cloud.updatedAt + 1;
        await prefs.setInt(timestampKey, localTimestamp);
        await prefs.setBool(adjustedKey, true);
      }

      if (localTimestamp == 0 || cloud.updatedAt >= localTimestamp) {
        await store.backupKnownWords();
        if (!_isCurrent(uid, generation)) return;
        if (store.wordStateRevision.value != startingRevision) {
          _queueRevisionRetry(uid, generation);
          return;
        }

        final beforeApplyRevision = store.wordStateRevision.value;
        final beforeSnapshot = store.wordStateSnapshot();
        final remoteIsIdentical =
            _sameWords(beforeSnapshot['known']!, cloud.known) &&
            _sameWords(beforeSnapshot['showAgain']!, cloud.showAgain);

        _applyingRemote = true;
        try {
          await store.replaceWordStates(
            known: cloud.known,
            showAgain: cloud.showAgain,
          );
        } finally {
          _applyingRemote = false;
        }
        if (!_isCurrent(uid, generation)) return;

        final expectedRevision = beforeApplyRevision + (remoteIsIdentical ? 0 : 1);
        if (store.wordStateRevision.value != expectedRevision) {
          // A genuine local edit raced the download. Keep the downloaded cloud
          // state as rollback baseline, then make the edit newer for upload.
          await store.markWordStateSnapshotAsSynced(
            uid: uid,
            known: cloud.known,
            showAgain: cloud.showAgain,
            updatedAt: cloud.updatedAt,
          );
          final localNow = _serverNowMilliseconds(serverOffset);
          await prefs.setInt(
            timestampKey,
            localNow > cloud.updatedAt ? localNow : cloud.updatedAt + 1,
          );
          await prefs.setBool(adjustedKey, true);
          _queueRevisionRetry(uid, generation);
          return;
        }

        await prefs.setInt(timestampKey, cloud.updatedAt);
        await prefs.setBool(adjustedKey, true);
        await store.markWordStateSnapshotAsSynced(
          uid: uid,
          known: cloud.known,
          showAgain: cloud.showAgain,
          updatedAt: cloud.updatedAt,
        );

        if (!_isCurrent(uid, generation)) return;
        if (store.wordStateRevision.value != expectedRevision) {
          final localNow = _serverNowMilliseconds(serverOffset);
          await prefs.setInt(
            timestampKey,
            localNow > cloud.updatedAt ? localNow : cloud.updatedAt + 1,
          );
          _queueRevisionRetry(uid, generation);
          return;
        }
      } else {
        // The local cache belongs to this UID and is newer than cloud.
        await _uploadSnapshot(uid, generation, prefs,
            serverOffset, timestampKey, adjustedKey);
        return;
      }

      if (!_isCurrent(uid, generation)) return;
      _markSynced();
    } catch (error, stackTrace) {
      debugPrint('Word-state synchronization failed: $error\n$stackTrace');
      if (_isCurrent(uid, generation)) {
        lastError.value = _friendlyError(error);
        status.value = WordSyncStatus.failed;
        _scheduleBackoffRetry(uid, generation);
      }
    }
  }

  int _serverNowMilliseconds(int serverOffset) =>
      DateTime.now().millisecondsSinceEpoch + serverOffset;

  void _markSynced() {
    _retryAttempt = 0;
    _retryTimer?.cancel();
    status.value = WordSyncStatus.synced;
    lastError.value = null;
    store.markWordStatesReady();
  }

  void _queueRevisionRetry(String uid, int generation) {
    if (!_isCurrent(uid, generation)) return;
    status.value = WordSyncStatus.pending;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () {
      if (_isCurrent(uid, generation)) unawaited(syncNow());
    });
  }

  void _scheduleBackoffRetry(String uid, int generation) {
    if (!_isCurrent(uid, generation) || !_firebaseConnected) return;
    const delays = <int>[2, 5, 15, 30, 60];
    final seconds = delays[_retryAttempt.clamp(0, delays.length - 1).toInt()];
    if (_retryAttempt < delays.length - 1) _retryAttempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (_isCurrent(uid, generation) && _firebaseConnected) {
        unawaited(syncNow());
      }
    });
  }

  Future<void> _uploadSnapshot(
    String uid,
    int generation,
    SharedPreferences prefs,
    int serverOffset,
    String timestampKey,
    String adjustedKey,
  ) async {
    if (!_isCurrent(uid, generation)) return;

    final revision = store.wordStateRevision.value;
    final snapshot = store.wordStateSnapshot();
    final known = List<String>.from(snapshot['known'] ?? const [])..sort();
    final showAgain =
        List<String>.from(snapshot['showAgain'] ?? const [])..sort();

    await _wordStatesRef(uid).set({
      'schemaVersion': _schemaVersion,
      'knownWordsJson': jsonEncode(known),
      'showAgainWordsJson': jsonEncode(showAgain),
      'updatedAt': ServerValue.timestamp,
    }).timeout(const Duration(seconds: 25));

    if (!_isCurrent(uid, generation)) return;

    final verifiedSnapshot = await _wordStatesRef(uid)
        .get()
        .timeout(const Duration(seconds: 15));
    final verified = _tryParseCloudSnapshot(verifiedSnapshot.value);
    if (verified == null) {
      throw const FormatException(
        'Firebase write could not be verified: the word-state snapshot is incomplete.',
      );
    }
    if (!_sameWords(verified.known, known) ||
        !_sameWords(verified.showAgain, showAgain)) {
      throw const FormatException(
        'Firebase write verification found different word-state data.',
      );
    }

    if (!_isCurrent(uid, generation)) return;
    // Record the exact snapshot that Firebase accepted even if newer local
    // edits happened while this upload was in flight.
    await store.markWordStateSnapshotAsSynced(
      uid: uid,
      known: known,
      showAgain: showAgain,
      updatedAt: verified.updatedAt,
    );

    if (store.wordStateRevision.value == revision &&
        _isCurrent(uid, generation)) {
      await prefs.setInt(timestampKey, verified.updatedAt);
      await prefs.setBool(adjustedKey, true);
      if (store.wordStateRevision.value != revision) {
        final localNow = _serverNowMilliseconds(serverOffset);
        await prefs.setInt(
          timestampKey,
          localNow > verified.updatedAt ? localNow : verified.updatedAt + 1,
        );
        _queueRevisionRetry(uid, generation);
        return;
      }
      _markSynced();
    } else if (_isCurrent(uid, generation)) {
      final localNow = _serverNowMilliseconds(serverOffset);
      await prefs.setInt(
        timestampKey,
        localNow > verified.updatedAt ? localNow : verified.updatedAt + 1,
      );
      await prefs.setBool(adjustedKey, true);
      _queueRevisionRetry(uid, generation);
    }
  }

  bool _sameWords(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
  }

  _CloudWordSnapshot? _tryParseCloudSnapshot(Object? raw) {
    if (raw is! Map) return null;
    late final Map<String, dynamic> cloud;
    try {
      cloud = Map<String, dynamic>.from(raw);
    } catch (_) {
      return null;
    }
    final rawVersion = cloud['schemaVersion'];
    final version = _asInt(rawVersion);
    if (rawVersion != null && version == null) {
      throw const FormatException(
        'Cloud word-state schema version is invalid. Cloud data was left untouched.',
      );
    }
    // Reject unknown future schemas before looking at their other fields. Even
    // if a future record has a missing timestamp, this older app must not
    // mistake it for a repairable legacy record and overwrite it.
    if (version != null && version != _schemaVersion) {
      throw FormatException(
        'This app cannot read cloud word-state schema version $version. '
        'Cloud data was left untouched.',
      );
    }

    final updatedAt = _asInt(cloud['updatedAt']);
    if (version == _schemaVersion) {
      if (updatedAt == null || updatedAt <= 0) {
        throw const FormatException(
          'The current cloud snapshot has no valid timestamp. Cloud data was left untouched.',
        );
      }
      final knownJson = cloud['knownWordsJson'];
      final showAgainJson = cloud['showAgainWordsJson'];
      if (knownJson is! String || showAgainJson is! String) return null;
      try {
        return _buildCloudSnapshot(
          known: _decodeWordsJson(knownJson),
          showAgain: _decodeWordsJson(showAgainJson),
          updatedAt: updatedAt,
        );
      } on FormatException {
        return null;
      }
    }

    // Backward compatibility for old complete snapshots. Missing lists are
    // ambiguous and repair from this UID's own cache; complete lists without
    // a timestamp are left untouched because last-write-wins cannot be safe.
    if (version == null) {
      final knownRaw = cloud['known'];
      final showAgainRaw = cloud['showAgain'];
      if (knownRaw is! List || showAgainRaw is! List) return null;
      if (updatedAt == null || updatedAt <= 0) {
        throw const FormatException(
          'The legacy cloud snapshot has no valid timestamp. Cloud data was left untouched.',
        );
      }
      return _buildCloudSnapshot(
        known: _asStringList(knownRaw),
        showAgain: _asStringList(showAgainRaw),
        updatedAt: updatedAt,
      );
    }

    // The only remaining case is an incomplete legacy record (e.g. the
    // timestamp-only object created by the earlier implementation).
    return null;
  }

  List<String> _decodeWordsJson(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! List) {
      throw const FormatException('Word-state JSON must contain a list.');
    }
    return _asStringList(decoded);
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num && value == value.toInt()) return value.toInt();
    return int.tryParse('$value');
  }

  List<String> _asStringList(Object? value) {
    if (value is! List) {
      throw const FormatException('Cloud word-state list has an invalid format.');
    }
    return value
        .map((item) => BookStore.normalizeWord(item.toString()))
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  _CloudWordSnapshot _buildCloudSnapshot({
    required List<String> known,
    required List<String> showAgain,
    required int updatedAt,
  }) {
    final normalizedKnown = known.toSet();
    final normalizedAgain = showAgain
        .where((word) => word.isNotEmpty && !normalizedKnown.contains(word))
        .toSet()
        .toList()
      ..sort();
    return _CloudWordSnapshot(
      known: normalizedKnown.toList()..sort(),
      showAgain: normalizedAgain,
      updatedAt: updatedAt,
    );
  }

  String _friendlyError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    if (message.length > 220) return '${message.substring(0, 217)}…';
    return message.isEmpty ? 'Unknown Firebase synchronization error.' : message;
  }

  Future<void> stop() async {
    _accountGeneration++;
    _debounce?.cancel();
    _retryTimer?.cancel();
    final subscription = _connectionSubscription;
    _connectionSubscription = null;
    _detachListener();
    _uid = null;
    _firebaseConnected = false;
    await subscription?.cancel();
    // Do not clear _activeSync before awaiting it. A second stop() call
    // (for example, a newly signed-in account starting while the previous
    // widget is disposing) must also wait for the same in-flight operation.
    final active = _activeSync;
    if (active != null) {
      try {
        await active;
      } catch (_) {
        // _performSync reports errors through status/lastError.
      }
    }
    if (identical(_activeSync, active)) _activeSync = null;
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
    lastError.dispose();
  }
}

class _CloudWordSnapshot {
  const _CloudWordSnapshot({
    required this.known,
    required this.showAgain,
    required this.updatedAt,
  });

  final List<String> known;
  final List<String> showAgain;
  final int updatedAt;
}
