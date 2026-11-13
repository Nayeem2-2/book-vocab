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
import '../widgets/play_widgets.dart';
import 'game_page.dart';

class ChapterPage extends StatefulWidget {
  const ChapterPage(
      {super.key,
      required this.store,
      required this.book,
      required this.chapter});
  final BookStore store;
  final BookData book;
  final ChapterData chapter;

  @override
  State<ChapterPage> createState() => _ChapterPageState();
}

class _ChapterPageState extends State<ChapterPage> {
  bool showKnown = false;
  String query = '';
  double _sliderValue = 0.0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final visible = widget.chapter.words.where((entry) {
          final state = widget.store.getWordState(entry.word);
          final known = state == WordState.known;
          final matchesStatus = showKnown || !known;
          final matchesQuery = query.isEmpty ||
              entry.word.toLowerCase().contains(query.toLowerCase()) ||
              entry.meanings
                  .any((m) => m.toLowerCase().contains(query.toLowerCase()));
          return matchesStatus && matchesQuery;
        }).toList();

        final knownInChapter = widget.chapter.words
            .where((w) => widget.store.getWordState(w.word) == WordState.known)
            .length;
        final unknownInChapter = widget.chapter.words.length - knownInChapter;

        return Scaffold(
          appBar: AppBar(
            title: Text(widget.chapter.title,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              PlayButton(
                store: widget.store,
                title: widget.chapter.title,
                chapters: [widget.chapter],
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Stack(
            children: [
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Column(
                      children: [
                        TextField(
                          onChanged: (value) =>
                              setState(() => query = value.trim()),
                          decoration: InputDecoration(
                            hintText: 'Search words or meanings',
                            prefixIcon: const Icon(Icons.search),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide:
                                  const BorderSide(color: Color(0xFFE8ECE7)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide:
                                  const BorderSide(color: Color(0xFFE8ECE7)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '$unknownInChapter unknown/review  •  $knownInChapter known',
                                style: const TextStyle(
                                    color: Colors.black54, fontSize: 13),
                              ),
                            ),
                            const Text('Show known',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 13)),
                            Switch(
                              value: showKnown,
                              onChanged: (value) =>
                                  setState(() => showKnown = value),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: visible.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(28),
                              child: Text(
                                query.isNotEmpty
                                    ? 'No matching words.'
                                    : showKnown
                                        ? 'This chapter has no words.'
                                        : 'All words in this chapter are marked known.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.black54, fontSize: 16),
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                            itemCount: visible.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final entry = visible[index];
                              final state =
                                  widget.store.getWordState(entry.word);

                              Color badgeColor;
                              String badgeText;

                              if (state == WordState.known) {
                                badgeColor = const Color(0xFF27845B);
                                badgeText = 'KNOWN';
                              } else if (state == WordState.showAgain) {
                                badgeColor = const Color(0xFFD97706);
                                badgeText = 'SHOW AGAIN';
                              } else {
                                badgeColor = Colors.transparent;
                                badgeText = '';
                              }

                              return Dismissible(
                                key: Key(entry.word),
                                direction: state == WordState.known
                                    ? DismissDirection.startToEnd
                                    : DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(left: 20),
                                  color: Colors.orange.withOpacity(0.2),
                                  child: const Icon(Icons.replay,
                                      color: Color(0xFFD97706)),
                                ),
                                secondaryBackground: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF27845B)
                                        .withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: const Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Text('Known',
                                          style: TextStyle(
                                              color: Color(0xFF27845B),
                                              fontWeight: FontWeight.bold)),
                                      SizedBox(width: 8),
                                      Icon(Icons.check_circle,
                                          color: Color(0xFF27845B)),
                                    ],
                                  ),
                                ),
                                confirmDismiss: (direction) async {
                                  if (state == WordState.known &&
                                      direction == DismissDirection.startToEnd) {
                                    widget.store.setWordState(
                                        entry.word, WordState.showAgain);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('Moved to Show Again'),
                                          duration:
                                              Duration(milliseconds: 600)),
                                    );
                                  } else if (state != WordState.known &&
                                      direction == DismissDirection.endToStart) {
                                    widget.store.setWordState(
                                        entry.word, WordState.known);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Row(
                                          children: [
                                            Icon(Icons.auto_awesome,
                                                color: Colors.amber, size: 18),
                                            SizedBox(width: 8),
                                            Text('✨ Marked as Known!'),
                                          ],
                                        ),
                                        duration: Duration(milliseconds: 800),
                                        backgroundColor: Color(0xFF27845B),
                                      ),
                                    );
                                  }
                                  return false;
                                },
                                child: Card(
                                  child: Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(16, 13, 8, 13),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                entry.word,
                                                style: const TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.w800),
                                              ),
                                              const SizedBox(height: 5),
                                              Text(
                                                entry.meanings.isEmpty
                                                    ? 'বাংলা অর্থ পাওয়া যায়নি'
                                                    : entry.meanings
                                                        .join('  •  '),
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  height: 1.45,
                                                  color: entry.meanings.isEmpty
                                                      ? Colors.black38
                                                      : const Color(0xFF426B59),
                                                ),
                                              ),
                                              if (badgeText.isNotEmpty &&
                                                  (showKnown ||
                                                      state ==
                                                          WordState.showAgain))
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          top: 5),
                                                  child: Text(
                                                    badgeText,
                                                    style: TextStyle(
                                                      color: badgeColor,
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      letterSpacing: 1,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: state == WordState.known
                                              ? 'Mark unknown'
                                              : 'Mark known',
                                          onPressed: () {
                                            final next = state == WordState.known
                                                ? WordState.unknown
                                                : WordState.known;
                                            widget.store
                                                .setWordState(entry.word, next);
                                            if (next == WordState.known) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                const SnackBar(
                                                  content: Row(
                                                    children: [
                                                      Icon(Icons.auto_awesome,
                                                          color: Colors.amber,
                                                          size: 18),
                                                      SizedBox(width: 8),
                                                      Text('✨ Marked as Known!'),
                                                    ],
                                                  ),
                                                  duration:
                                                      Duration(milliseconds: 800),
                                                  backgroundColor:
                                                      Color(0xFF27845B),
                                                ),
                                              );
                                            }
                                          },
                                          icon: Icon(
                                            state == WordState.known
                                                ? Icons.check_circle_rounded
                                                : Icons.radio_button_unchecked,
                                            color: state == WordState.known
                                                ? const Color(0xFF27845B)
                                                : Colors.black38,
                                            size: 28,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'Mark as Show Again',
                                          onPressed: () {
                                            widget.store.setWordState(
                                                entry.word, WordState.showAgain);
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content:
                                                    Text('Flagged for Show Again'),
                                                duration:
                                                    Duration(milliseconds: 600),
                                              ),
                                            );
                                          },
                                          icon: Icon(
                                            state == WordState.showAgain
                                                ? Icons.replay_circle_filled_rounded
                                                : Icons.replay,
                                            color: state == WordState.showAgain
                                                ? const Color(0xFFD97706)
                                                : Colors.black38,
                                            size: 26,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
              Positioned(
                left: 16,
                bottom: 16,
                child: Container(
                  width: 150,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                        color: const Color(0xFF356859).withOpacity(0.3)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.08),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 45),
                        child: Text(
                          'Slide to mark all →',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF356859),
                          ),
                        ),
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 48,
                          activeTrackColor: Colors.transparent,
                          inactiveTrackColor: Colors.transparent,
                          thumbColor: const Color(0xFF356859),
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 22),
                          overlayColor: Colors.transparent,
                        ),
                        child: Slider(
                          value: _sliderValue,
                          onChanged: (val) {
                            setState(() => _sliderValue = val);
                            if (val == 1.0) {
                              widget.store.markAllChapterKnown(widget.chapter);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      '✨ All eligible words marked known (Show Again protected)!'),
                                  backgroundColor: Color(0xFF27845B),
                                ),
                              );
                              Future.delayed(const Duration(milliseconds: 300),
                                  () {
                                if (mounted) setState(() => _sliderValue = 0.0);
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
