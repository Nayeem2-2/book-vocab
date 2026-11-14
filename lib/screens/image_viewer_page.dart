import 'dart:io';

import 'package:flutter/material.dart';

import '../models/book_models.dart';

/// Full-screen image viewer. Its page sequence is inherited from the active
/// vocabulary navigation mode (alphabetical or original scan/import order).
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.book,
    required this.pages,
    required this.initialPageIndex,
  });

  final BookData book;
  final List<ChapterData> pages;
  final int initialPageIndex;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialPageIndex
        .clamp(0, widget.pages.isEmpty ? 0 : widget.pages.length - 1)
        .toInt();
  }

  ChapterData? get _currentPage =>
      widget.pages.isEmpty ? null : widget.pages[_currentIndex];

  void _showPrevious() {
    if (_currentIndex <= 0) return;
    setState(() => _currentIndex--);
  }

  void _showNext() {
    if (_currentIndex >= widget.pages.length - 1) return;
    setState(() => _currentIndex++);
  }

  void _minimizeToVocabulary() {
    Navigator.of(context).pop(_currentPage?.stableId);
  }

  @override
  Widget build(BuildContext context) {
    final page = _currentPage;

    return Scaffold(
      backgroundColor: const Color(0xFF171A18),
      appBar: AppBar(
        backgroundColor: const Color(0xFF171A18),
        foregroundColor: Colors.white,
        title: Text(
          page?.title ?? 'Page image',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        leading: IconButton(
          tooltip: 'Minimize to vocabulary',
          onPressed: _minimizeToVocabulary,
          icon: const Icon(Icons.minimize_rounded),
        ),
        actions: const [],
      ),
      body: page == null
          ? const Center(
              child: Text(
                'No page image available',
                style: TextStyle(color: Colors.white70),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final imagePath = page.imagePath;
                if (imagePath == null || imagePath.isEmpty) {
                  return const Center(
                    child: Text(
                      'Page image unavailable',
                      style: TextStyle(color: Colors.white70),
                    ),
                  );
                }

                return Stack(
                  children: [
                    Positioned.fill(
                      child: Center(
                        child: InteractiveViewer(
                          key: ValueKey(page.stableId),
                          minScale: 1,
                          maxScale: 6,
                          panEnabled: true,
                          scaleEnabled: true,
                          boundaryMargin: const EdgeInsets.all(72),
                          child: SizedBox(
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                            child: Image.file(
                              File(imagePath),
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Center(
                                child: Text(
                                  'Could not load this page image',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 18,
                      bottom: 22,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _NavigationButton(
                            icon: Icons.chevron_left_rounded,
                            tooltip: 'Previous page',
                            enabled: _currentIndex > 0,
                            onPressed: _showPrevious,
                          ),
                          const SizedBox(width: 10),
                          _NavigationButton(
                            icon: Icons.chevron_right_rounded,
                            tooltip: 'Next page',
                            enabled: _currentIndex < widget.pages.length - 1,
                            onPressed: _showNext,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _NavigationButton extends StatelessWidget {
  const _NavigationButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(enabled ? 0.94 : 0.35),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        onPressed: enabled ? onPressed : null,
        icon: Icon(
          icon,
          size: 30,
          color: enabled ? const Color(0xFF24352C) : Colors.black38,
        ),
      ),
    );
  }
}
