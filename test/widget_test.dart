
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/app.dart';
import '../lib/services/book_store.dart';
import '../lib/services/google_auth_service.dart';
import '../lib/services/word_state_sync_service.dart';

// Fake authentication service: does not connect to Firebase.
class FakeGoogleAuthService implements GoogleAuthService {
  @override
  Stream<User?> get authStateChanges => Stream<User?>.value(null);

  @override
  User? get currentUser => null;

  @override
  Future<UserCredential> signInWithGoogle() async {
    throw UnimplementedError('Sign-in is not tested here.');
  }

  @override
  Future<void> signOut() async {}
}

// Fake synchronization service: does not connect to Firebase.
class FakeWordStateSyncService implements WordStateSyncService {
  FakeWordStateSyncService(this.store);

  @override
  final BookStore store;

  final ValueNotifier<WordSyncStatus> _status =
      ValueNotifier<WordSyncStatus>(WordSyncStatus.pending);

  @override
  ValueNotifier<WordSyncStatus> get status => _status;

  // Added to match the updated WordStateSyncService interface.
  @override
  final ValueNotifier<String?> lastError =
      ValueNotifier<String?>(null);

  @override
  void attachForUser(String uid) {}

  @override
  Future<void> syncNow() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await stop();
    _status.dispose();
    lastError.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Vocabulary app opens the sign-in screen',
      (WidgetTester tester) async {
    final store = BookStore();
    final authService = FakeGoogleAuthService();
    final syncService = FakeWordStateSyncService(store);

    addTearDown(syncService.dispose);

    await tester.pumpWidget(
      VocabularyApp(
        store: store,
        authService: authService,
        syncService: syncService,
      ),
    );

    // Wait for the fake authentication stream to emit its signed-out state.
    await tester.pumpAndSettle();

    expect(find.text('Book Vocabulary'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);

    // Remove the widget before disposing the test service.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
