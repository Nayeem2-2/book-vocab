import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_store.dart';

enum WordSyncStatus { synced, pending, syncing, failed }

/// Synchronizes only the global Known / Show Again word-state snapshot.
/// Books, pages, images and dictionary data are deliberately never uploaded.
///
/// Schema v2 stores both lists as JSON strings. This makes even an empty list
/// an explicit scalar value and lets the app verify that the snapshot is whole.
class WordStateSyncService {
  WordStateSyncService({required this.store, FirebaseDatabase? database})
      : _database = database ?? FirebaseDatabase.instance;

  final BookStore store;
  final FirebaseDatabase _database;

  final ValueNotifier<WordSyncStatus> status =
      ValueNotifier<WordSyncStatus>(WordSyncStatus.pending);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  static const _localTimestampKey = 'word_states_last_modified_at';
  static const _timestampAdjustedKey = 'word_states_timestamp_server_adjusted';
  static const _serverOffsetKey = 'word_states_server_time_offset_ms';
  static const int _schemaVersion = 2;

  StreamSubscription<DatabaseEvent>? _connectionSubscription;
  Timer? _debounce;
  String? _uid;
  Future<void>? _activeSync;
  bool _disposed = false;
  bool _listenerAttached = false;
  bool _applyingRemote = false;
  int _accountGeneration = 0;

  DatabaseReference _wordStatesRef(String uid) =>
      _database.ref('users/$uid/wordStates');

  /// Starts local-change and connectivity monitoring for the authenticated UID.
  void attachForUser(String uid) {
    if (_uid == uid && _listenerAttached) return;

    _accountGeneration++;
    _debounce?.cancel();
    unawaited(_connectionSubscription?.cancel());
    _connectionSubscription = null;
    _detachListener();
    _activeSync = null;
    _uid = uid;
    lastError.value = null;
    status.value = WordSyncStatus.pending;

    store.wordStateRevision.addListener(_onLocalRevision);
    _listenerAttached = true;
    final generation = _accountGeneration;
    _connectionSubscription = _database.ref('.info/connected').onValue.listen(
      (event) {
        final connected = event.snapshot.value == true;
        if (connected && _isCurrent(uid, generation) &&
            (status.value == WordSyncStatus.pending ||
                status.value == WordSyncStatus.failed)) {
          unawaited(syncNow());
        }
      },
      onError: (Object error) {
        debugPrint('Firebase connection monitor error: $error');
      },
    );
  }

  void _onLocalRevision() {
    if (_uid == null || _disposed || _applyingRemote) return;
    _recordLocalChange();
  }

  void _recordLocalChange() {
    if (_uid == null || _disposed) return;
    status.value = WordSyncStatus.pending;
    lastError.value = null;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1600), () {
      unawaited(syncNow());
    });
  }

  bool _isCurrent(String uid, int generation) =>
      !_disposed && _uid == uid && _accountGeneration == generation;

  Future<void> syncNow() {
    final uid = _uid;
    if (uid == null || _disposed) return Future<void>.value();
    final active = _activeSync;
    if (active != null) return active;

    _debounce?.cancel();
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
      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrent(uid, generation)) return;

      // Obtain Firebase's estimate of server time. If it is temporarily
      // unavailable, retain the last known offset and continue using local
      // data; the actual database read below will report connectivity errors.
      final savedOffset = prefs.getInt(_serverOffsetKey) ?? 0;
      var serverOffset = savedOffset;
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

      var localTimestamp = prefs.getInt(_localTimestampKey) ?? 0;
      final timestampWasAdjusted =
          prefs.getBool(_timestampAdjustedKey) ?? false;
      if (localTimestamp > 0 && !timestampWasAdjusted && receivedFreshOffset) {
        // Timestamps written by older app builds used the device clock.
        // Convert that one existing value once; future edits use server offset.
        localTimestamp += serverOffset;
        await prefs.setInt(_localTimestampKey, localTimestamp);
        await prefs.setBool(_timestampAdjustedKey, true);
      } else if (receivedFreshOffset && !timestampWasAdjusted) {
        await prefs.setBool(_timestampAdjustedKey, true);
      }

      final startingRevision = store.wordStateRevision.value;
      final cloudSnapshot = await _wordStatesRef(uid)
          .get()
          .timeout(const Duration(seconds: 15));
      if (!_isCurrent(uid, generation)) return;

      if (store.wordStateRevision.value != startingRevision) {
        _queueRetry(uid, generation);
        return;
      }

      if (!cloudSnapshot.exists || cloudSnapshot.value == null) {
        // First sign-in for this account: seed it from the existing local data.
        await _uploadSnapshot(uid, generation, startingRevision);
        return;
      }

      final cloud = _tryParseCloudSnapshot(cloudSnapshot.value);
      if (cloud == null) {
        // A timestamp-only or otherwise incomplete legacy record is not an
        // empty snapshot. Never apply it to the local store. Repair it using
        // the current local snapshot, which remains the recovery source.
        debugPrint(
          'Incomplete cloud word-state snapshot for $uid; repairing from local data.',
        );
        await _uploadSnapshot(uid, generation, startingRevision);
        return;
      }

      final cloudTimestamp = cloud.updatedAt;
      if (localTimestamp == 0 || cloudTimestamp >= localTimestamp) {
        // Back up local data before any destructive replacement.
        await store.backupKnownWords();
        if (!_isCurrent(uid, generation)) return;
        if (store.wordStateRevision.value != startingRevision) {
          _queueRetry(uid, generation);
          return;
        }

        final revisionBeforeRemoteApply = store.wordStateRevision.value;
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

        final expectedRemoteRevision = revisionBeforeRemoteApply + 1;
        if (store.wordStateRevision.value != expectedRemoteRevision) {
          // A concurrent local edit happened while the downloaded snapshot
          // was being saved. Keep the local edit newer and upload it next.
          final newestLocalTime = _serverNowMilliseconds(serverOffset);
          await prefs.setInt(
            _localTimestampKey,
            newestLocalTime > cloudTimestamp
                ? newestLocalTime
                : cloudTimestamp + 1,
          );
          await prefs.setBool(_timestampAdjustedKey, true);
          _queueRetry(uid, generation);
          return;
        }

        await prefs.setInt(_localTimestampKey, cloudTimestamp);
        await prefs.setBool(_timestampAdjustedKey, true);
        if (store.wordStateRevision.value != expectedRemoteRevision) {
          final newestLocalTime = _serverNowMilliseconds(serverOffset);
          await prefs.setInt(
            _localTimestampKey,
            newestLocalTime > cloudTimestamp
                ? newestLocalTime
                : cloudTimestamp + 1,
          );
          _queueRetry(uid, generation);
          return;
        }
      } else {
        // The local snapshot is newer than the valid cloud snapshot.
        await _uploadSnapshot(uid, generation, startingRevision);
        return;
      }

      if (!_isCurrent(uid, generation)) return;
      if (store.wordStateRevision.value !=
          (startingRevision + (cloudTimestamp >= localTimestamp ? 1 : 0))) {
        _queueRetry(uid, generation);
      } else {
        status.value = WordSyncStatus.synced;
        lastError.value = null;
      }
    } catch (error, stackTrace) {
      debugPrint('Word-state synchronization failed: $error\n$stackTrace');
      if (_isCurrent(uid, generation)) {
        lastError.value = _friendlyError(error);
        status.value = WordSyncStatus.failed;
      }
    }
  }

  int _serverNowMilliseconds(int serverOffset) =>
      DateTime.now().millisecondsSinceEpoch + serverOffset;

  void _queueRetry(String uid, int generation) {
    if (!_isCurrent(uid, generation)) return;
    status.value = WordSyncStatus.pending;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () {
      if (_isCurrent(uid, generation)) unawaited(syncNow());
    });
  }

  Future<void> _uploadSnapshot(
    String uid,
    int generation,
    int revision,
  ) async {
    if (!_isCurrent(uid, generation)) return;

    final snapshot = store.wordStateSnapshot();
    final known = snapshot['known'] ?? <String>[];
    final showAgain = snapshot['showAgain'] ?? <String>[];

    // JSON strings make both lists explicit, including when either is empty,
    // and allow the app to verify that it read back the complete snapshot.
    await _wordStatesRef(uid).set({
      'schemaVersion': _schemaVersion,
      'knownWordsJson': jsonEncode(known),
      'showAgainWordsJson': jsonEncode(showAgain),
      'updatedAt': ServerValue.timestamp,
    }).timeout(const Duration(seconds: 25));

    if (!_isCurrent(uid, generation)) return;

    // Read back and validate the entire object, not just the timestamp. This
    // catches partial writes or unexpected database serialization behavior.
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

    if (store.wordStateRevision.value == revision &&
        _isCurrent(uid, generation)) {
      final prefs = await SharedPreferences.getInstance();
      if (store.wordStateRevision.value != revision ||
          !_isCurrent(uid, generation)) {
        _queueRetry(uid, generation);
        return;
      }
      await prefs.setInt(_localTimestampKey, verified.updatedAt);
      await prefs.setBool(_timestampAdjustedKey, true);
      // Recheck after the asynchronous preference write. A word edit that
      // raced with this upload must remain newer than the uploaded snapshot.
      if (store.wordStateRevision.value != revision) {
        final offset = prefs.getInt(_serverOffsetKey) ?? 0;
        final localNow = _serverNowMilliseconds(offset);
        await prefs.setInt(
          _localTimestampKey,
          localNow > verified.updatedAt ? localNow : verified.updatedAt + 1,
        );
        _queueRetry(uid, generation);
        return;
      }
      if (_isCurrent(uid, generation)) {
        status.value = WordSyncStatus.synced;
        lastError.value = null;
      }
    } else if (_isCurrent(uid, generation)) {
      _queueRetry(uid, generation);
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
    final updatedAt = _asInt(cloud['updatedAt']);
    if (updatedAt == null || updatedAt <= 0) return null;

    final rawVersion = cloud['schemaVersion'];
    final version = _asInt(rawVersion);
    if (rawVersion != null && version == null) {
      throw const FormatException(
        'Cloud word-state schema version is invalid. Cloud data was left untouched.',
      );
    }
    if (version == _schemaVersion) {
      final knownJson = cloud['knownWordsJson'];
      final showAgainJson = cloud['showAgainWordsJson'];
      if (knownJson is! String || showAgainJson is! String) return null;
      try {
        return _CloudWordSnapshot(
          known: _decodeWordsJson(knownJson),
          showAgain: _decodeWordsJson(showAgainJson),
          updatedAt: updatedAt,
        );
      } on FormatException {
        return null;
      }
    }

    // Backward compatibility for the previous {known: [...],
    // showAgain: [...], updatedAt: ...} schema. Both lists must be present.
    // A partially missing legacy record is ambiguous, so repair it from the
    // local snapshot rather than interpreting missing data as an empty list.
    if (version == null) {
      final knownRaw = cloud['known'];
      final showAgainRaw = cloud['showAgain'];
      if (knownRaw is! List || showAgainRaw is! List) return null;
      return _CloudWordSnapshot(
        known: _asStringList(knownRaw),
        showAgain: _asStringList(showAgainRaw),
        updatedAt: updatedAt,
      );
    }

    // Do not overwrite a record written by a future app version that this
    // installed build cannot understand.
    throw FormatException(
      'This app cannot read cloud word-state schema version $version. '
      'Cloud data was left untouched.',
    );
  }

  List<String> _decodeWordsJson(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! List) {
      throw const FormatException('Word-state JSON must contain a list.');
    }
    return _asStringList(decoded);
  }

  int? _asInt(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value');

  List<String> _asStringList(Object? value) {
    if (value is! List) {
      throw const FormatException('Cloud word-state list has an invalid format.');
    }
    return value.map((item) => item.toString()).toList();
  }

  String _friendlyError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    if (message.length > 220) return '${message.substring(0, 217)}…';
    return message.isEmpty ? 'Unknown Firebase synchronization error.' : message;
  }

  Future<void> stop() async {
    _accountGeneration++;
    _debounce?.cancel();
    final subscription = _connectionSubscription;
    _connectionSubscription = null;
    _detachListener();
    _uid = null;
    _activeSync = null;
    await subscription?.cancel();
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
