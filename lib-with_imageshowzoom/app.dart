import 'package:flutter/material.dart';

import 'screens/books_page.dart';
import 'services/book_store.dart';

class VocabularyApp extends StatelessWidget {
  const VocabularyApp({super.key, required this.store});
  final BookStore store;

  @override
  Widget build(BuildContext context) {
    // Keep MaterialApp stable. Individual screens listen to BookStore so a
    // word/page update does not rebuild the Navigator and inherited widgets.
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
      home: BooksPage(store: store),
    );
  }
}
