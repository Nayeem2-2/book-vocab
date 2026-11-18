import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'screens/books_page.dart';
import 'services/book_store.dart';
import 'services/google_auth_service.dart';
import 'services/word_state_sync_service.dart';

class VocabularyApp extends StatelessWidget {
  const VocabularyApp({
    super.key,
    required this.store,
    required this.authService,
    required this.syncService,
  });

  final BookStore store;
  final GoogleAuthService authService;
  final WordStateSyncService syncService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Book Vocabulary',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF356859),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8F5),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFE8ECE7)),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF7F8F5),
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
        ),
      ),
      home: _AuthenticationGate(
        store: store,
        authService: authService,
        syncService: syncService,
      ),
    );
  }
}

class _AuthenticationGate extends StatelessWidget {
  const _AuthenticationGate({
    required this.store,
    required this.authService,
    required this.syncService,
  });

  final BookStore store;
  final GoogleAuthService authService;
  final WordStateSyncService syncService;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: authService.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _LoadingScreen(message: 'Checking your account…');
        }
        final user = snapshot.data;
        if (user == null) {
          return _SignInPage(authService: authService);
        }
        return _SignedInHome(
          key: ValueKey(user.uid),
          user: user,
          store: store,
          authService: authService,
          syncService: syncService,
        );
      },
    );
  }
}

class _SignedInHome extends StatefulWidget {
  const _SignedInHome({
    super.key,
    required this.user,
    required this.store,
    required this.authService,
    required this.syncService,
  });

  final User user;
  final BookStore store;
  final GoogleAuthService authService;
  final WordStateSyncService syncService;

  @override
  State<_SignedInHome> createState() => _SignedInHomeState();
}

class _SignedInHomeState extends State<_SignedInHome> {
  bool _loadingLocalAccount = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _activateLocalAccount();
  }

  Future<void> _activateLocalAccount() async {
    try {
      // Wait for any previous UID's in-flight sync to stop before changing the
      // active local word-state set. This prevents an old download from
      // mutating the new account's in-memory state during a quick account
      // switch. stop() is safe when no account is currently attached.
      await widget.syncService.stop();

      // Activate only this UID's cache. This operation is local and does not
      // wait for the network, so a returning user can open the app offline.
      await widget.store.activateAccount(widget.user.uid);
      if (!mounted) return;

      widget.syncService.attachForUser(widget.user.uid);
      setState(() => _loadingLocalAccount = false);

      // Firebase synchronization runs in the background. If this account has
      // no local cache, word-state editing remains locked until the first
      // successful cloud check establishes this account's snapshot.
      unawaited(widget.syncService.syncNow());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.toString();
        _loadingLocalAccount = false;
      });
    }
  }

  @override
  void dispose() {
    unawaited(widget.syncService.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingLocalAccount) {
      return const _LoadingScreen(message: 'Loading your local vocabulary…');
    }
    if (_loadError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load this account’s local data: $_loadError'),
          ),
        ),
      );
    }
    return BooksPage(
      store: widget.store,
      trailingAction: _AccountButton(
        user: widget.user,
        authService: widget.authService,
        syncService: widget.syncService,
        store: widget.store,
      ),
    );
  }
}

class _SignInPage extends StatefulWidget {
  const _SignInPage({required this.authService});
  final GoogleAuthService authService;

  @override
  State<_SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<_SignInPage> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.authService.signInWithGoogle();
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    if (error is FirebaseAuthException) {
      return error.message ?? 'Google sign-in failed (${error.code}).';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5F0EA),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Icon(
                      Icons.menu_book_rounded,
                      size: 40,
                      color: Color(0xFF356859),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Book Vocabulary',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Sign in to sync your word progress across your devices.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54, height: 1.5),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _signIn,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: Text(_busy ? 'Signing in…' : 'Continue with Google'),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 18),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountButton extends StatelessWidget {
  const _AccountButton({
    required this.user,
    required this.authService,
    required this.syncService,
    required this.store,
  });

  final User user;
  final GoogleAuthService authService;
  final WordStateSyncService syncService;
  final BookStore store;

  Future<void> _signOut(BuildContext context) async {
    // Close the account dialog before doing network work.
    Navigator.of(context).pop();
    try {
      await syncService.syncNow();
      if (!context.mounted) return;
      final hasPendingChanges = await store.hasUnsyncedWordStateChanges();
      if (!context.mounted) return;

      if (hasPendingChanges) {
        final discard = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Unsynchronized changes'),
            content: const Text(
              'Some vocabulary changes have not reached Firebase. '
              'Signing out will discard those pending changes and restore '
              'this account’s last successfully synchronized snapshot. '
              'Previously synchronized progress will be kept.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                ),
                child: const Text('Discard and sign out'),
              ),
            ],
          ),
        );
        if (discard != true) return;

        await syncService.stop();
        await store.restoreLastSyncedWordStates();
      } else {
        await syncService.stop();
      }

      // The account file remains on disk for the next time this UID signs in.
      // Only the in-memory active word-state set is cleared.
      await store.clearActiveAccountWordStates();
      await authService.signOut();
    } catch (error) {
      // If recovery/sign-out fails, reload this UID's cache before restoring
      // its sync listener. Never resume with a cleared in-memory snapshot.
      if (store.activeAccountUid == null) {
        try {
          await store.activateAccount(user.uid);
        } catch (restoreError) {
          debugPrint('Could not restore the account cache after sign-out error: $restoreError');
        }
      }
      syncService.attachForUser(user.uid);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not sign out safely: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Account and sync status',
      onPressed: () => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Account & sync'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user.email ?? user.displayName ?? 'Google account'),
              const SizedBox(height: 16),
              ValueListenableBuilder<WordSyncStatus>(
                valueListenable: syncService.status,
                builder: (context, currentStatus, _) => Row(
                  children: [
                    Icon(_statusIcon(currentStatus), size: 20),
                    const SizedBox(width: 9),
                    Expanded(child: Text(_statusText(currentStatus))),
                  ],
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: syncService.lastError,
                builder: (context, error, _) {
                  if (error == null || error.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Details: $error',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.redAccent,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'Only Known and Show Again word states are synchronized.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                syncService.syncNow();
              },
              child: const Text('Sync now'),
            ),
            TextButton(
              onPressed: () => _signOut(context),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
      icon: const Icon(Icons.account_circle_outlined),
    );
  }

  IconData _statusIcon(WordSyncStatus status) => switch (status) {
        WordSyncStatus.synced => Icons.cloud_done_outlined,
        WordSyncStatus.pending => Icons.cloud_upload_outlined,
        WordSyncStatus.syncing => Icons.sync,
        WordSyncStatus.failed => Icons.cloud_off_outlined,
      };

  String _statusText(WordSyncStatus status) => switch (status) {
        WordSyncStatus.synced => 'Synced',
        WordSyncStatus.pending => 'Pending sync',
        WordSyncStatus.syncing => 'Synchronizing…',
        WordSyncStatus.failed => 'Sync failed — local data is safe',
      };
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            Text(message),
          ],
        ),
      ),
    );
  }
}
