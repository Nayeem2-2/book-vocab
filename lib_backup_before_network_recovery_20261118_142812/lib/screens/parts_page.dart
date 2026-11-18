import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_models.dart';
import '../services/book_store.dart';
import '../widgets/shared_widgets.dart';
import '../widgets/play_widgets.dart';
import 'chapters_page.dart';

class PartsPage extends StatelessWidget {
  const PartsPage({super.key, required this.store, required this.book});
  final BookStore store;
  final BookData book;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: store,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
              title: Text(book.name,
                  style: const TextStyle(fontWeight: FontWeight.w800))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              BookProgress(store: store, book: book),
              const SizedBox(height: 14),
              for (var i = 0; i < book.parts.length; i++)
                FolderTile(
                  title: book.parts[i].title,
                  subtitle: [
                    '${book.parts[i].chapters.length} Chapters',
                    if (book.parts[i].pageRange.isNotEmpty)
                      book.parts[i].pageRange,
                  ].join('  •  '),
                  icon: Icons.folder_rounded,
                  play: PlayButton(
                    store: store,
                    title: book.parts[i].title,
                    chapters: book.parts[i].chapters,
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChaptersPage(
                          store: store, book: book, part: book.parts[i]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}
