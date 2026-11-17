import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'firebase_options.dart';
import 'services/book_store.dart';
import 'services/google_auth_service.dart';
import 'services/word_state_sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  final store = BookStore();
  await store.init();

  final authService = GoogleAuthService();
  final syncService = WordStateSyncService(store: store);

  runApp(VocabularyApp(
    store: store,
    authService: authService,
    syncService: syncService,
  ));
}
