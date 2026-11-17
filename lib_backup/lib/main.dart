import 'package:flutter/material.dart';

import 'app.dart';
import 'services/book_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = BookStore();
  await store.init();

  runApp(VocabularyApp(store: store));
}
