import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/book_models.dart';
import 'services/book_store.dart';
import 'screens/books_page.dart';

class VocabularyApp extends StatelessWidget {
  const VocabularyApp({super.key, required this.store});
  final BookStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => MaterialApp(
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
      ),
    );
  }
}

// ───────────────────────── Data models ─────────────────────────
