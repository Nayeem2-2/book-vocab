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
import 'chapter_page.dart';

class ChaptersPage extends StatelessWidget {
  const ChaptersPage(
      {super.key,
      required this.store,
      required this.book,
      required this.part});
  final BookStore store;
  final BookData book;
  final PartData part;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: store,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
              title: Text(part.title,
                  style: const TextStyle(fontWeight: FontWeight.w800))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (part.pageRange.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(part.pageRange,
                      style: const TextStyle(color: Colors.black54)),
                ),
              for (final chapter in part.chapters)
                FolderTile(
                  title: chapter.title,
                  subtitle: [
                    '${chapter.words.length} words',
                    if (chapter.pageRange.isNotEmpty) chapter.pageRange,
                  ].join('  •  '),
                  icon: Icons.folder_open_rounded,
                  play: PlayButton(
                    store: store,
                    title: chapter.title,
                    chapters: [chapter],
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChapterPage(
                          store: store, book: book, chapter: chapter),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}
