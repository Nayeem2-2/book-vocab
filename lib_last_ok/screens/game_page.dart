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

class GamePage extends StatefulWidget {
  const GamePage({
    super.key,
    required this.store,
    required this.title,
    required this.chapters,
    this.includeUnknown = true,
    this.includeShowAgain = true,
  });
  final BookStore store;
  final String title;
  final List<ChapterData> chapters;
  final bool includeUnknown;
  final bool includeShowAgain;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> with TickerProviderStateMixin {
  static const _green = Color(0xFF27845B);
  static const _red = Color(0xFFC0392B);
  static const _ink = Color(0xFF1F3D33);

  late final AnimationController _enter;
  late final AnimationController _exit;
  late final AnimationController _idle;

  late List<WordEntry> _queue;
  int _total = 0;
  int _knownCount = 0;
  int _skips = 0;
  bool _busy = false;
  bool _exitKnown = true;

  /// Meaning stays hidden until "Show meaning" is pressed; resets per word.
  bool _showMeaning = false;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 380));
    _exit = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _idle = AnimationController(vsync: this, duration: const Duration(seconds: 4))
      ..repeat();

    _queue = widget.store.practiceWords(
      widget.chapters,
      includeUnknown: widget.includeUnknown,
      includeShowAgain: widget.includeShowAgain,
    )..shuffle();
    _total = _queue.length;
    if (_queue.isNotEmpty) _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    _exit.dispose();
    _idle.dispose();
    super.dispose();
  }

  Future<void> _answer(bool known) async {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    _exitKnown = known;
    HapticFeedback.lightImpact();
    await _exit.forward(from: 0);
    if (!mounted) return;

    final entry = _queue.removeAt(0);
    if (known) {
      _knownCount++;
      // Global: the word becomes known in every book, part and chapter.
      widget.store.setWordState(entry.word, WordState.known);
    } else {
      // Unknown: clear showAgain globally and send the bubble to the end.
      widget.store.setWordState(entry.word, WordState.unknown);
      _queue.add(entry);
      _skips++;
    }

    _enter.value = 0;
    _exit.value = 0;
    _showMeaning = false;
    setState(() {});
    _busy = false;
    if (_queue.isNotEmpty) _enter.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title,
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _queue.isEmpty ? _finished(context) : _playing(),
    );
  }

  Widget _finished(BuildContext context) {
    final nothing = _total == 0;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🎉', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 14),
            Text(
              nothing ? 'Nothing to practise' : 'Round complete!',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              nothing
                  ? 'No words match the options you picked.'
                  : '$_knownCount words marked known'
                      '${_skips > 0 ? '  •  $_skips skipped' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54, fontSize: 16),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playing() {
    final progress = _total == 0 ? 0.0 : _knownCount / _total;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('$_knownCount known  •  ${_queue.length} left',
                      style: const TextStyle(
                          color: Colors.black54, fontWeight: FontWeight.w600)),
                  Text('Skipped $_skips',
                      style: const TextStyle(color: Colors.black45)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(value: progress, minHeight: 8),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final h = c.maxHeight;
              final d = math.min(math.min(w * 0.88, h * 0.86), 360.0);
              const previewAlign = [
                Alignment(-0.82, -0.85),
                Alignment(0.85, -0.6),
                Alignment(-0.7, 0.85),
              ];
              const previewSize = [0.26, 0.19, 0.22];
              final previewCount = math.min(_queue.length - 1, 3);

              return AnimatedBuilder(
                animation: Listenable.merge([_enter, _exit, _idle]),
                builder: (context, _) {
                  if (_queue.isEmpty) return const SizedBox.shrink();
                  final phase = _idle.value * 2 * math.pi;
                  final enterT = Curves.easeOutCubic.transform(_enter.value);

                  double dx = math.sin(phase) * 6;
                  double dy = math.cos(phase) * 8 + (1 - enterT) * h * 0.8;
                  double scale = 1;
                  double opacity = math.min(1.0, _enter.value * 3);

                  if (_exit.value > 0) {
                    final t = Curves.easeIn.transform(_exit.value);
                    if (_exitKnown) {
                      // Pop
                      scale = 1 + 0.35 * t;
                      opacity *= (1 - t);
                      dy -= h * 0.04 * t;
                    } else {
                      // Fly off toward the Unknown button (bottom-left)
                      dx -= w * 0.45 * t;
                      dy += h * 0.3 * t;
                      scale = 1 - 0.6 * t;
                      opacity *= (1 - t);
                    }
                  }

                  return Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      for (var i = 0; i < previewCount; i++)
                        Align(
                          alignment: previewAlign[i],
                          child: Transform.translate(
                            offset: Offset(math.sin(phase + i * 2) * 5,
                                math.cos(phase + i * 2) * 7),
                            child: Container(
                              width: d * previewSize[i],
                              height: d * previewSize[i],
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF356859).withOpacity(0.08),
                                border: Border.all(
                                  color:
                                      const Color(0xFF356859).withOpacity(0.18),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Center(
                        child: Transform.translate(
                          offset: Offset(dx, dy),
                          child: Transform.scale(
                            scale: scale,
                            child: Opacity(
                              opacity: opacity.clamp(0.0, 1.0),
                              child: _bubble(_queue.first, d),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF356859),
                      side: BorderSide(
                          color: const Color(0xFF356859).withOpacity(0.5)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () =>
                        setState(() => _showMeaning = !_showMeaning),
                    icon: Icon(_showMeaning
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    label: Text(
                      _showMeaning ? 'Hide meaning' : 'Show meaning',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: _red,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                          ),
                          onPressed: () => _answer(false),
                          icon: const Icon(Icons.close_rounded, size: 28),
                          label: const Text('Unknown',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: _green,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                          ),
                          onPressed: () => _answer(true),
                          icon: const Icon(Icons.check_rounded, size: 28),
                          label: const Text('Known',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _bubble(WordEntry entry, double d) {
    final state = widget.store.getWordState(entry.word);
    final meaning = entry.meanings.isEmpty
        ? 'বাংলা অর্থ পাওয়া যায়নি'
        : entry.meanings.join('  •  ');

    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          center: Alignment(-0.35, -0.4),
          radius: 0.95,
          colors: [Colors.white, Color(0xFFE3F1EA), Color(0xFFBFDCCE)],
          stops: [0.0, 0.65, 1.0],
        ),
        border: Border.all(
            color: const Color(0xFF356859).withOpacity(0.35), width: 2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF356859).withOpacity(0.22),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: SizedBox(
        width: d * 0.72,
        height: d * 0.6,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: d * 0.72,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state == WordState.showAgain)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Text(
                      'SHOW AGAIN',
                      style: TextStyle(
                        color: Color(0xFFD97706),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                Text(
                  entry.word,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: _ink,
                  ),
                ),
                if (_showMeaning) ...[
                  const SizedBox(height: 12),
                  Text(
                    meaning,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 20,
                      height: 1.4,
                      color: entry.meanings.isEmpty
                          ? Colors.black38
                          : const Color(0xFF426B59),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
