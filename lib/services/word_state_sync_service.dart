import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_store.dart';

enum WordSyncStatus { synced, pending, syncing, failed, offline, reconnecting }

/// Synchronizes one complete Known / Show Again snapshot for the active UID.
/// Books, pages, images, OCR data and dictionary data are never uploaded.
class WordStateSyncService {
  WordStateSyncService({
    required this.store,
    FirebaseDatabase? database,
    Connectivity? connectivity,
  })  : _database = database ?? FirebaseDatabase.instance,
        _connectivity = connectivity ?? Connectivity();

  final BookStore store;
  final FirebaseDatabase _database;
  final Connectivity _connectivity;

  final ValueNotifier<WordSyncStatus> status =
      ValueNotifier<WordSyncStatus>(WordSyncStatus.pending);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  static const int _schemaVersion = 2;
  static const String _serverOffsetKey = 'word_states_server_time_offset_ms';

  StreamSubscription<DatabaseEvent>? _connectionSubscription;
  StreamSubscription<List<ConnectivityResult>>? _networkSubscription;
  AppLifecycleListener? _lifecycleListener;
  Timer? _debounce;
  Timer? _retryTimer;
  Timer? _recoveryTimer;
  Timer? _connectionListenerRestartTimer;
  Timer? _networkListenerRestartTimer;
  String? _uid;
  Future<void>? _activeSync;
  bool _disposed = false;
  bool _listenerAttached = false;
  bool _applyingRemote = false;
  bool _firebaseConnected = false;
  bool? _deviceNetworkAvailable;
  bool _networkCheckInProgress = false;
  bool _firebaseProbeInProgress = false;
  bool _connectionListenerRestartInProgress = false;
  bool _networkListenerRestartInProgress = false;
  bool _recoveryCheckInProgress = false;
  int _connectionListenerEpoch = 0;
  DateTime? _lastReconnectKickAt;
  // A reconnect (or another explicit sync request) that occurs while a sync
  // is running must not be lost. The current operation is allowed to finish
  // or time out, then exactly one fresh attempt is started immediately.
  bool _syncRequestedAfterActive = false;
  int _accountGeneration = 0;
  int _retryAttempt = 0;

  DatabaseReference _wordStatesRef(String uid) =>
      _database.ref('users/$uid/wordStates');

  String _localTimestampKey(String uid) =>
      'word_states_last_modified_at_${BookStore.accountStorageKey(uid)}';

  String _timestampAdjustedKey(String uid) =>
      'word_states_timestamp_server_adjusted_${BookStore.accountStorageKey(uid)}';

  /// Starts local-change, device-network, app-lifecycle and Firebase connection
  /// monitoring for one UID. Device network state is only an early warning;
  /// Firebase's own connection signal remains authoritative for synchronization.
  void attachForUser(String uid) {
    if (_uid == uid && _listenerAttached) return;

    _accountGeneration++;
    _debounce?.cancel();
    _retryTimer?.cancel();
    _recoveryTimer?.cancel();
    _connectionListenerRestartTimer?.cancel();
    _networkListenerRestartTimer?.cancel();
    unawaited(_connectionSubscription?.cancel());
    unawaited(_networkSubscription?.cancel());
    _connectionSubscription = null;
    _networkSubscription = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    _detachListener();
    _activeSync = null;
    _syncRequestedAfterActive = false;
    _uid = uid;
    _firebaseConnected = false;
    _deviceNetworkAvailable = null;
    _networkCheckInProgress = false;
    _firebaseProbeInProgress = false;
    _connectionListenerRestartInProgress = false;
    _networkListenerRestartInProgress = false;
    _recoveryCheckInProgress = false;
    _retryAttempt = 0;
    _lastReconnectKickAt = null;
    lastError.value = null;
    status.value = WordSyncStatus.pending;

    store.wordStateRevision.addListener(_onLocalRevision);
    _listenerAttached = true;
    final generation = _accountGeneration;

    _lifecycleListener = AppLifecycleListener(
      onResume: () => unawaited(_handleAppResumed(uid, generation)),
    );
    _attachFirebaseConnectionListener(uid, generation);
    _attachNetworkListener(uid, generation);
    _ensureRecoveryTimer(uid, generation);
    unawaited(_refreshDeviceNetwork(uid, generation));
  }

  void _attachFirebaseConnectionListener(String uid, int generation) {
    if (!_isCurrent(uid, generation) || _connectionSubscription != null) {
      return;
    }

    final epoch = ++_connectionListenerEpoch;
    late final StreamSubscription<DatabaseEvent> subscription;
    subscription = _database.ref('.info/connected').onValue.listen(
      (event) {
        if (!_isCurrent(uid, generation) ||
            epoch != _connectionListenerEpoch) {
          return;
        }
        _handleFirebaseConnectionValue(
          event.snapshot.value == true,
          uid,
          generation,
        );
      },
      onError: (Object error) {
        if (!_isCurrent(uid, generation) ||
            epoch != _connectionListenerEpoch) {
          return;
        }
        debugPrint('Firebase connection monitor error: $error');
        _connectionSubscription = null;
        _firebaseConnected = false;
        _setConnectionWaitingStatus();
        _ensureRecoveryTimer(uid, generation);
        unawaited(subscription.cancel());
        _scheduleFirebaseConnectionListenerRestart(uid, generation);
      },
      onDone: () {
        if (!_isCurrent(uid, generation) ||
            epoch != _connectionListenerEpoch) {
          return;
        }
        debugPrint('Firebase connection monitor stream ended; restarting it.');
        _connectionSubscription = null;
        _firebaseConnected = false;
        _setConnectionWaitingStatus();
        _ensureRecoveryTimer(uid, generation);
        _scheduleFirebaseConnectionListenerRestart(uid, generation);
      },
    );
    _connectionSubscription = subscription;
  }

  void _handleFirebaseConnectionValue(
    bool connected,
    String uid,
    int generation,
  ) {
    if (!_isCurrent(uid, generation)) return;
    final wasConnected = _firebaseConnected;
    _firebaseConnected = connected;

    if (connected) {
      // A successful Firebase connection is stronger evidence than the
      // device-network plugin, whose events can briefly lag during Wi-Fi/mobile
      // handoffs. From this point Firebase itself confirms reachability.
      _deviceNetworkAvailable = true;
      debugPrint('[FIREBASE] Realtime Database connected.');
      _lastReconnectKickAt = null;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
      _retryTimer?.cancel();
      _retryAttempt = 0;
      if (!wasConnected ||
          status.value == WordSyncStatus.offline ||
          status.value == WordSyncStatus.reconnecting) {
        _debounce?.cancel();
        if (_activeSync != null) {
          _syncRequestedAfterActive = true;
          status.value = WordSyncStatus.pending;
          lastError.value =
              'Firebase reconnected — an immediate synchronization check is queued.';
        } else {
          unawaited(syncNow());
        }
      } else if (status.value == WordSyncStatus.pending &&
          _activeSync == null) {
        unawaited(syncNow());
      }
      return;
    }

    // A returning account may continue with its own previously synced cache
    // while offline. A new account without a cache remains read-only until its
    // first successful cloud reconciliation.
    debugPrint('[FIREBASE] Realtime Database disconnected.');
    store.markCachedWordStatesReadyOffline();
    _debounce?.cancel();
    _retryTimer?.cancel();
    _setConnectionWaitingStatus();
    _ensureRecoveryTimer(uid, generation);
  }

  void _attachNetworkListener(String uid, int generation) {
    if (!_isCurrent(uid, generation) || _networkSubscription != null) return;
    try {
      late final StreamSubscription<List<ConnectivityResult>> subscription;
      subscription = _connectivity.onConnectivityChanged.listen(
        (results) => _handleDeviceNetworkResults(results, uid, generation),
        onError: (Object error) {
          if (!_isCurrent(uid, generation)) return;
          debugPrint('Device network monitor error: $error');
          _networkSubscription = null;
          unawaited(subscription.cancel());
          _scheduleNetworkListenerRestart(uid, generation);
        },
        onDone: () {
          if (!_isCurrent(uid, generation)) return;
          debugPrint('Device network monitor stream ended; restarting it.');
          _networkSubscription = null;
          _scheduleNetworkListenerRestart(uid, generation);
        },
      );
      _networkSubscription = subscription;
    } catch (error) {
      debugPrint('Could not attach device network monitor: $error');
      _scheduleNetworkListenerRestart(uid, generation);
    }
  }

  void _handleDeviceNetworkResults(
    List<ConnectivityResult> results,
    String uid,
    int generation,
  ) {
    if (!_isCurrent(uid, generation)) return;
    // Any reported network transport means an interface is available. This
    // is only a reason to test Firebase, never proof that the Internet itself
    // is reachable (for example, Wi-Fi may be connected without Internet).
    // Include Bluetooth tethering and less common transports rather than
    // incorrectly declaring them Offline.
    final available = results.any(
      (result) => result != ConnectivityResult.none,
    );
    final wasAvailable = _deviceNetworkAvailable;
    _deviceNetworkAvailable = available;
    if (wasAvailable != available) {
      debugPrint(
        '[NETWORK] ${available ? "Interface available" : "No network interface"}; results=$results',
      );
    }

    if (!available) {
      // Report the device-side outage immediately. Keep Firebase's last signal
      // intact: its listener remains the source of truth about RTDB reachability.
      // The 20-second recovery check and the next network event reconcile both.
      _lastReconnectKickAt = null;
      store.markCachedWordStatesReadyOffline();
      _setConnectionWaitingStatus();
      _debounce?.cancel();
      _retryTimer?.cancel();
      _ensureRecoveryTimer(uid, generation);
      return;
    }

    if (wasAvailable != true || !_firebaseConnected) {
      // Network returned (or Firebase is still disconnected despite an
      // available interface): bypass backoff and actively revive the RTDB
      // connection monitor. This is only a prompt; .info/connected remains
      // the authority that allows a sync to start.
      _requestFirebaseReconnect(uid, generation);
    } else if (status.value == WordSyncStatus.pending &&
        _activeSync == null) {
      unawaited(syncNow());
    }
  }

  Future<void> _refreshDeviceNetwork(String uid, int generation) async {
    if (!_isCurrent(uid, generation) || _networkCheckInProgress) return;
    _networkCheckInProgress = true;
    try {
      final results = await _connectivity
          .checkConnectivity()
          .timeout(const Duration(seconds: 5));
      if (_isCurrent(uid, generation)) {
        _handleDeviceNetworkResults(results, uid, generation);
      }
    } catch (error) {
      // If this secondary plugin is unavailable, do not keep a stale
      // `false` value that could block a healthy Firebase connection. Let
      // Firebase remain authoritative until the next successful interface
      // check. If Firebase is already connected, treat reachability as proven.
      debugPrint('Device network check failed; relying on Firebase: $error');
      if (_isCurrent(uid, generation)) {
        _deviceNetworkAvailable = _firebaseConnected ? true : null;
        if (!_firebaseConnected) {
          _setConnectionWaitingStatus();
          _ensureRecoveryTimer(uid, generation);
        }
      }
    } finally {
      _networkCheckInProgress = false;
    }
  }

  Future<void> _handleAppResumed(String uid, int generation) async {
    if (!_isCurrent(uid, generation)) return;
    // Android may not deliver network-change events while the app is in the
    // background. Re-query the active interface as soon as the app resumes.
    await _refreshDeviceNetwork(uid, generation);
    if (!_isCurrent(uid, generation)) return;
    if (_deviceNetworkAvailable == true && !_firebaseConnected) {
      _requestFirebaseReconnect(uid, generation);
    } else if (_firebaseConnected &&
        status.value == WordSyncStatus.pending &&
        _activeSync == null) {
      unawaited(syncNow());
    }
  }

  void _requestFirebaseReconnect(String uid, int generation) {
    if (!_isCurrent(uid, generation)) return;
    _retryTimer?.cancel();
    _retryAttempt = 0;

    if (_firebaseConnected && _deviceNetworkAvailable != false) {
      if (_activeSync != null) {
        _syncRequestedAfterActive = true;
        status.value = WordSyncStatus.pending;
        lastError.value = 'Connection restored — a sync check is queued.';
      } else if (status.value != WordSyncStatus.synced) {
        unawaited(syncNow());
      }
      return;
    }

    if (_deviceNetworkAvailable == false) {
      _setConnectionWaitingStatus();
      _ensureRecoveryTimer(uid, generation);
      return;
    }

    final now = DateTime.now();
    final lastKick = _lastReconnectKickAt;
    if (lastKick != null &&
        now.difference(lastKick) < const Duration(seconds: 2)) {
      _ensureRecoveryTimer(uid, generation);
      return;
    }
    _lastReconnectKickAt = now;

    debugPrint('[SYNC] Requesting Firebase reconnect.');
    status.value = WordSyncStatus.reconnecting;
    lastError.value = _deviceNetworkAvailable == true
        ? 'Device network is available; reconnecting to Firebase.'
        : 'Checking device network and Firebase connection.';
    _ensureRecoveryTimer(uid, generation);
    unawaited(_restartFirebaseConnectionListener(uid, generation));
    unawaited(_pokeFirebaseConnection(uid, generation));
  }

  Future<void> _restartFirebaseConnectionListener(
    String uid,
    int generation,
  ) async {
    if (!_isCurrent(uid, generation) ||
        _connectionListenerRestartInProgress) {
      return;
    }
    _connectionListenerRestartInProgress = true;
    final previous = _connectionSubscription;
    _connectionSubscription = null;
    _connectionListenerEpoch++;
    try {
      await previous?.cancel();
      if (_isCurrent(uid, generation)) {
        _attachFirebaseConnectionListener(uid, generation);
      }
    } catch (error) {
      debugPrint('Error replacing Firebase connection listener: $error');
      _scheduleFirebaseConnectionListenerRestart(uid, generation);
    } finally {
      _connectionListenerRestartInProgress = false;
    }
  }

  void _scheduleFirebaseConnectionListenerRestart(
    String uid,
    int generation,
  ) {
    if (!_isCurrent(uid, generation) ||
        _connectionListenerRestartTimer?.isActive == true) {
      return;
    }
    _connectionListenerRestartTimer = Timer(
      const Duration(seconds: 2),
      () {
        _connectionListenerRestartTimer = null;
        unawaited(_restartFirebaseConnectionListener(uid, generation));
      },
    );
  }

  void _scheduleNetworkListenerRestart(String uid, int generation) {
    if (!_isCurrent(uid, generation) ||
        _networkListenerRestartTimer?.isActive == true) {
      return;
    }
    _networkListenerRestartTimer = Timer(const Duration(seconds: 3), () {
      _networkListenerRestartTimer = null;
      if (!_isCurrent(uid, generation) ||
          _networkListenerRestartInProgress) {
        return;
      }
      _networkListenerRestartInProgress = true;
      final previous = _networkSubscription;
      _networkSubscription = null;
      unawaited(() async {
        try {
          await previous?.cancel();
        } catch (error) {
          debugPrint('Error replacing device network listener: $error');
        }
        if (_isCurrent(uid, generation)) {
          _attachNetworkListener(uid, generation);
          await _refreshDeviceNetwork(uid, generation);
        }
        _networkListenerRestartInProgress = false;
      }());
    });
  }

  Future<void> _pokeFirebaseConnection(String uid, int generation) async {
    if (!_isCurrent(uid, generation) || _firebaseProbeInProgress) return;
    _firebaseProbeInProgress = true;
    try {
      // A small read prompts the Firebase SDK to resume its normal connection
      // work. It is NOT treated as proof of connectivity because some clients
      // may satisfy reads from cache while offline. Only .info/connected=true
      // permits syncNow() to proceed.
      await _wordStatesRef(uid)
          .child('updatedAt')
          .get()
          .timeout(const Duration(seconds: 8));
    } catch (error) {
      debugPrint('Firebase reconnect probe did not complete: $error');
    } finally {
      _firebaseProbeInProgress = false;
    }
  }

  void _ensureRecoveryTimer(String uid, int generation) {
    if (!_isCurrent(uid, generation) || _recoveryTimer?.isActive == true) {
      return;
    }
    // A low-frequency recovery check protects against missed plugin events or
    // a stale/terminated Firebase stream. It performs no upload by itself.
    _recoveryTimer = Timer.periodic(const Duration(seconds: 20), (timer) {
      if (!_isCurrent(uid, generation)) {
        timer.cancel();
        if (identical(_recoveryTimer, timer)) _recoveryTimer = null;
        return;
      }
      if (_firebaseConnected && _deviceNetworkAvailable != false) {
        timer.cancel();
        if (identical(_recoveryTimer, timer)) _recoveryTimer = null;
        return;
      }
      unawaited(_runRecoveryCheck(uid, generation));
    });
  }

  Future<void> _runRecoveryCheck(String uid, int generation) async {
    if (!_isCurrent(uid, generation) || _recoveryCheckInProgress) return;
    _recoveryCheckInProgress = true;
    try {
      await _refreshDeviceNetwork(uid, generation);
      if (!_isCurrent(uid, generation) || _deviceNetworkAvailable != true) {
        return;
      }
      if (_firebaseConnected) {
        if (_activeSync == null && status.value != WordSyncStatus.synced) {
          unawaited(syncNow());
        }
        return;
      }
      // Reattach the .info listener periodically in case its original stream
      // terminated without a usable event, then issue a lightweight RTDB read.
      await _restartFirebaseConnectionListener(uid, generation);
      if (_isCurrent(uid, generation) && !_firebaseConnected) {
        await _pokeFirebaseConnection(uid, generation);
      }
    } finally {
      _recoveryCheckInProgress = false;
    }
  }

  void _setConnectionWaitingStatus() {
    if (_deviceNetworkAvailable == false) {
      status.value = WordSyncStatus.offline;
      lastError.value = store.hasLocalAccountCache
          ? 'Device network: unavailable. Firebase: disconnected. Changes are saved locally for this account.'
          : 'Device network: unavailable. Firebase: disconnected. Waiting for this account’s first cloud sync.';
    } else if (_deviceNetworkAvailable == true) {
      status.value = WordSyncStatus.reconnecting;
      lastError.value =
          'Device network: available. Firebase: not connected yet; checking reachability.';
    } else {
      status.value = WordSyncStatus.reconnecting;
      lastError.value =
          'Device network: checking. Firebase: connection not yet confirmed.';
    }
  }

  void _onLocalRevision() {
    if (_uid == null || _disposed || _applyingRemote) return;
    _recordLocalChange();
  }

  void _recordLocalChange() {
    final uid = _uid;
    if (uid == null || _disposed) return;
    if (_firebaseConnected && _deviceNetworkAvailable != false) {
      status.value = WordSyncStatus.pending;
      lastError.value = null;
    } else {
      _setConnectionWaitingStatus();
      if (_uid != null) _ensureRecoveryTimer(_uid!, _accountGeneration);
    }
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

  /// Attempts immediately when Firebase is confirmed connected and the
  /// device monitor does not report no available network. Offline calls leave
  /// the local snapshot untouched; network, Firebase and app-resume monitors
  /// retry later. If a request is active, one follow-up attempt is queued.
  Future<void> syncNow() {
    final uid = _uid;
    if (uid == null || _disposed) return Future<void>.value();
    final active = _activeSync;
    if (active != null) {
      // Do not start overlapping reads/writes. Remember the request so it is
      // executed immediately after the active operation completes or times out.
      if (_firebaseConnected && _deviceNetworkAvailable != false) {
        _syncRequestedAfterActive = true;
        _retryTimer?.cancel();
        _debounce?.cancel();
      }
      return active;
    }

    _debounce?.cancel();
    if (!_firebaseConnected || _deviceNetworkAvailable == false) {
      _setConnectionWaitingStatus();
      _ensureRecoveryTimer(uid, _accountGeneration);
      return Future<void>.value();
    }

    final generation = _accountGeneration;
    late final Future<void> tracked;
    tracked = _performSync(uid, generation).whenComplete(() {
      if (!identical(_activeSync, tracked)) return;
      _activeSync = null;

      final runQueuedAttempt = _syncRequestedAfterActive;
      _syncRequestedAfterActive = false;
      if (runQueuedAttempt &&
          _isCurrent(uid, generation) &&
          _firebaseConnected &&
          _deviceNetworkAvailable != false) {
        // Schedule after the current future has fully settled and _activeSync
        // has been cleared. This is an immediate retry, not a backoff retry.
        _retryTimer?.cancel();
        _debounce?.cancel();
        scheduleMicrotask(() {
          if (_isCurrent(uid, generation) &&
              _firebaseConnected &&
              _deviceNetworkAvailable != false &&
              _activeSync == null) {
            unawaited(syncNow());
          }
        });
      }
    });
    _activeSync = tracked;
    return tracked;
  }

  Future<void> _performSync(String uid, int generation) async {
    if (!_isCurrent(uid, generation)) return;
    debugPrint('[SYNC] Synchronization started.');
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
        // .info/serverTimeOffset is documented as a value-listener location.
        // Use the initial stream event rather than a one-shot Query.get().
        final offsetEvent = await _database
            .ref('.info/serverTimeOffset')
            .onValue
            .first
            .timeout(const Duration(seconds: 5));
        final value = offsetEvent.snapshot.value;
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
        if (!_firebaseConnected || _deviceNetworkAvailable == false) {
          // A request may time out after a disconnection. Keep the state
          // offline/reconnecting, not failed. Device and Firebase monitors
          // will trigger a fresh attempt when the server is reachable.
          _setConnectionWaitingStatus();
          _ensureRecoveryTimer(uid, generation);
        } else {
          lastError.value = _friendlyError(error);
          status.value = WordSyncStatus.failed;
          _scheduleBackoffRetry(uid, generation);
        }
      }
    }
  }

  int _serverNowMilliseconds(int serverOffset) =>
      DateTime.now().millisecondsSinceEpoch + serverOffset;

  void _markSynced() {
    _retryAttempt = 0;
    _retryTimer?.cancel();
    store.markWordStatesReady();

    // A completed request is not enough to report Synced if the database
    // disconnected during it, or if a reconnect has already queued a fresh
    // validation pass.
    if (!_firebaseConnected || _deviceNetworkAvailable == false) {
      _setConnectionWaitingStatus();
      _ensureRecoveryTimer(_uid!, _accountGeneration);
      return;
    }
    if (_syncRequestedAfterActive) {
      status.value = WordSyncStatus.pending;
      lastError.value = 'Connection restored — checking the latest snapshot.';
      return;
    }

    debugPrint('[SYNC] Latest word-state snapshot verified.');
    status.value = WordSyncStatus.synced;
    lastError.value = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
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
    // A connection-restoration retry has priority over exponential backoff.
    if (!_isCurrent(uid, generation) ||
        !_firebaseConnected ||
        _deviceNetworkAvailable == false ||
        _syncRequestedAfterActive) {
      return;
    }
    const delays = <int>[2, 5, 15, 30, 60];
    final seconds = delays[_retryAttempt.clamp(0, delays.length - 1).toInt()];
    if (_retryAttempt < delays.length - 1) _retryAttempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (_isCurrent(uid, generation) &&
          _firebaseConnected) {
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
    _recoveryTimer?.cancel();
    _connectionListenerRestartTimer?.cancel();
    _networkListenerRestartTimer?.cancel();
    final connectionSubscription = _connectionSubscription;
    final networkSubscription = _networkSubscription;
    _connectionSubscription = null;
    _networkSubscription = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    _detachListener();
    _uid = null;
    _firebaseConnected = false;
    _deviceNetworkAvailable = null;
    _networkCheckInProgress = false;
    _firebaseProbeInProgress = false;
    _recoveryCheckInProgress = false;
    _syncRequestedAfterActive = false;
    await connectionSubscription?.cancel();
    await networkSubscription?.cancel();
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
