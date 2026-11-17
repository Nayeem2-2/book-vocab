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
  late final Future<void> _initialSync;

  @override
  void initState() {
    super.initState();
    widget.syncService.attachForUser(widget.user.uid);
    _initialSync = widget.syncService.syncNow();
  }

  @override
  void dispose() {
    widget.syncService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initialSync,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _LoadingScreen(
            message: 'Synchronizing your vocabulary…',
          );
        }
        return BooksPage(
          store: widget.store,
          trailingAction: _AccountButton(
            user: widget.user,
            authService: widget.authService,
            syncService: widget.syncService,
          ),
        );
      },
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
  });

  final User user;
  final GoogleAuthService authService;
  final WordStateSyncService syncService;

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
                builder: (context, status, _) => Row(
                  children: [
                    Icon(_statusIcon(status), size: 20),
                    const SizedBox(width: 9),
                    Expanded(child: Text(_statusText(status))),
                  ],
                ),
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
              onPressed: () async {
                Navigator.pop(dialogContext);
                await authService.signOut();
              },
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
