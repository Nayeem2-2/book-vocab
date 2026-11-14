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
import '../screens/game_page.dart';

Future<void> startGame(
  BuildContext context,
  BookStore store,
  String title,
  List<ChapterData> chapters, {
  PracticeCounts? initialCounts,
}) async {
  final counts = initialCounts ?? store.practiceCounts(chapters);
  if (counts.total == 0) return;

  final choice = await showModalBottomSheet<PlayChoice>(
    context: context,
    showDragHandle: true,
    backgroundColor: Colors.white,
    builder: (_) => PlayOptionsSheet(title: title, counts: counts),
  );
  if (choice == null || !context.mounted) return;

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => GamePage(
        store: store,
        title: title,
        chapters: chapters,
        includeUnknown: choice.unknown,
        includeShowAgain: choice.showAgain,
      ),
    ),
  );
}
class PlayOptionsSheet extends StatefulWidget {
  const PlayOptionsSheet({required this.title, required this.counts});
  final String title;
  final PracticeCounts counts;

  @override
  State<PlayOptionsSheet> createState() => PlayOptionsSheetState();
}

class PlayOptionsSheetState extends State<PlayOptionsSheet> {
  late bool _unknown = widget.counts.unknown > 0;
  late bool _again = widget.counts.showAgain > 0;

  int get _selected =>
      (_unknown ? widget.counts.unknown : 0) +
      (_again ? widget.counts.showAgain : 0);

  @override
  Widget build(BuildContext context) {
    final c = widget.counts;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Choose which words to play',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _unknown,
              onChanged: c.unknown > 0
                  ? (v) => setState(() => _unknown = v ?? false)
                  : null,
              title: const Text('Unknown',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${c.unknown} words not marked yet'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _again,
              onChanged: c.showAgain > 0
                  ? (v) => setState(() => _again = v ?? false)
                  : null,
              title: const Text('Show again',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${c.showAgain} words flagged to review'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _selected == 0
                    ? null
                    : () => Navigator.pop(
                          context,
                          PlayChoice(unknown: _unknown, showAgain: _again),
                        ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(
                  _selected == 0
                      ? 'Tick at least one option'
                      : 'Start  •  $_selected words',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Play icon used on books, parts and chapters. Faded and disabled when the
/// scope has no unknown / show again words left.
class PlayButton extends StatelessWidget {
  const PlayButton({
    super.key,
    required this.store,
    required this.title,
    required this.chapters,
    this.size = 32,
    this.book,
  });
  final BookStore store;
  final String title;
  final List<ChapterData> chapters;
  final double size;
  final BookData? book;

  static const _green = Color(0xFF356859);

  Widget _buildButton(BuildContext context, PracticeCounts counts) {
    final enabled = counts.total > 0;
    return IconButton(
      tooltip: enabled
          ? 'Play • ${counts.total} words to practise'
          : 'Nothing to practise',
      icon: Icon(
        Icons.play_circle_fill_rounded,
        size: size,
        color: enabled ? _green : _green.withOpacity(0.25),
      ),
      onPressed: enabled
          ? () => startGame(
                context,
                store,
                title,
                chapters,
                initialCounts: counts,
              )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (book != null) {
      // Whole-book statistics can cover hundreds of thousands of word
      // entries. The shared Future yields between small chunks, so the list
      // keeps responding while the index is prepared.
      return ValueListenableBuilder<int>(
        valueListenable: store.wordStateRevision,
        builder: (context, _, __) => FutureBuilder<void>(
          future: store.ensureBookWordCache(book!),
          builder: (context, snapshot) {
            final counts = store.cachedPracticeCountsForBook(book!);
            if (counts == null) {
              return SizedBox(
                width: size + 16,
                height: size + 16,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _green.withOpacity(0.65),
                  ),
                ),
              );
            }
            return _buildButton(context, counts);
          },
        ),
      );
    }

    return ValueListenableBuilder<int>(
      valueListenable: store.wordStateRevision,
      builder: (context, _, __) => _buildButton(
        context,
        store.practiceCounts(chapters),
      ),
    );
  }
}

// ───────────────────────── Books page ─────────────────────────
