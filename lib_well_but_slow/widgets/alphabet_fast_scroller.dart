import 'package:flutter/material.dart';

/// Filters and sorts names with exact matches first, then prefix matches,
/// followed by substring matches. Results within each relevance group are
/// alphabetically ordered.
List<T> rankAndSortByName<T>(
  Iterable<T> values,
  String Function(T value) nameOf,
  String query,
) {
  final normalizedQuery = query.trim().toLowerCase();
  final result = values.where((value) {
    return normalizedQuery.isEmpty ||
        nameOf(value).toLowerCase().contains(normalizedQuery);
  }).toList();

  int rank(T value) {
    if (normalizedQuery.isEmpty) return 0;
    final name = nameOf(value).trim().toLowerCase();
    if (name == normalizedQuery) return 0;
    if (name.startsWith(normalizedQuery)) return 1;
    return 2;
  }

  result.sort((a, b) {
    final rankDifference = rank(a).compareTo(rank(b));
    if (rankDifference != 0) return rankDifference;
    return nameOf(a).trim().toLowerCase().compareTo(
          nameOf(b).trim().toLowerCase(),
        );
  });
  return result;
}

/// Alphabetical fast-scroll rail used by Books, Pages and page vocabulary.
///
/// The rail stays subtly visible when idle. During touch/drag it becomes fully
/// visible and displays a five-letter focal preview around the active letter.
/// For regular lists [itemExtent] maps an alphabet position to a row offset.
/// For grouped/variable-height lists, supply [onLetterSelected] and scroll to
/// the matching section yourself (for example with Scrollable.ensureVisible).
class AlphabetFastScroller extends StatefulWidget {
  const AlphabetFastScroller({
    super.key,
    required this.controller,
    required this.names,
    required this.itemExtent,
    this.onLetterSelected,
  });

  final ScrollController controller;
  final List<String> names;
  final double itemExtent;
  final ValueChanged<String>? onLetterSelected;

  @override
  State<AlphabetFastScroller> createState() => _AlphabetFastScrollerState();
}

class _AlphabetFastScrollerState extends State<AlphabetFastScroller> {
  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  bool _interacting = false;
  int? _activeIndex;
  double _activeY = 0;

  int? _findNearestAvailableIndex(int requestedIndex) {
    if (widget.names.isEmpty) return null;

    var forwardIndex = -1;
    var forwardGap = 27;
    var backwardIndex = -1;
    var backwardGap = 27;

    for (var i = 0; i < widget.names.length; i++) {
      final name = widget.names[i].trim();
      if (name.isEmpty) continue;
      final initial = name[0].toUpperCase();
      final letterIndex = _alphabet.indexOf(initial);
      if (letterIndex < 0) continue;

      final gap = letterIndex - requestedIndex;
      if (gap >= 0 && gap < forwardGap) {
        forwardGap = gap;
        forwardIndex = i;
      } else if (gap < 0 && -gap < backwardGap) {
        backwardGap = -gap;
        backwardIndex = i;
      }
    }

    if (forwardIndex < 0) return backwardIndex < 0 ? null : backwardIndex;
    if (backwardIndex < 0) return forwardIndex;
    return forwardGap <= backwardGap ? forwardIndex : backwardIndex;
  }

  void _moveTo(double localY, double railHeight) {
    if (widget.names.isEmpty || railHeight <= 0) return;

    final normalized = (localY / railHeight).clamp(0.0, 0.999999);
    final requestedIndex = (normalized * _alphabet.length).floor();
    final nearestIndex = _findNearestAvailableIndex(requestedIndex);

    setState(() {
      _interacting = true;
      _activeIndex = requestedIndex;
      _activeY = localY.clamp(0.0, railHeight - 1).toDouble();
    });

    if (nearestIndex == null) return;

    final selectedName = widget.names[nearestIndex].trim();
    if (selectedName.isEmpty) return;
    final selectedLetter = selectedName[0].toUpperCase();

    if (widget.onLetterSelected != null) {
      widget.onLetterSelected!(selectedLetter);
      return;
    }

    if (!widget.controller.hasClients || widget.itemExtent <= 0) return;
    final position = widget.controller.position;
    final offset = (nearestIndex * widget.itemExtent)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    widget.controller.jumpTo(offset);
  }

  void _finishInteraction() {
    if (!mounted || !_interacting) return;
    setState(() {
      _interacting = false;
      _activeIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.names.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (height <= 0) return const SizedBox.shrink();

        final activeIndex = _activeIndex ?? 0;
        final bubbleHeight = 126.0;
        final bubbleTop = (_activeY - bubbleHeight / 2)
            .clamp(0.0, (height - bubbleHeight).clamp(0.0, height).toDouble())
            .toDouble();

        return Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => _moveTo(details.localPosition.dy, height),
              onTapUp: (_) => _finishInteraction(),
              onTapCancel: _finishInteraction,
              onVerticalDragStart: (details) =>
                  _moveTo(details.localPosition.dy, height),
              onVerticalDragUpdate: (details) =>
                  _moveTo(details.localPosition.dy, height),
              onVerticalDragEnd: (_) => _finishInteraction(),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: _interacting ? 1.0 : 0.30,
                child: SizedBox(
                  width: 26,
                  height: height,
                  child: Column(
                    children: List.generate(
                      _alphabet.length,
                      (index) {
                        final isActive = _interacting && index == _activeIndex;
                        return Expanded(
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 100),
                              style: TextStyle(
                                fontSize: isActive ? 13 : 9.5,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                color: isActive
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                              ),
                              child: Text(_alphabet[index]),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            if (_interacting && _activeIndex != null)
              Positioned(
                right: 30,
                top: bubbleTop,
                child: IgnorePointer(
                  child: Material(
                    elevation: 7,
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(24),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOutCubic,
                      width: 62,
                      height: bubbleHeight,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.18),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(5, (position) {
                          final distance = position - 2;
                          final letterIndex = activeIndex + distance;
                          final inRange =
                              letterIndex >= 0 && letterIndex < _alphabet.length;
                          final isCurrent = distance == 0;
                          final sizes = [10.0, 15.0, 29.0, 15.0, 10.0];
                          final opacities = [0.28, 0.55, 1.0, 0.55, 0.28];

                          return SizedBox(
                            height: 23,
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 100),
                                style: TextStyle(
                                  fontSize: sizes[position],
                                  height: 1,
                                  fontWeight: isCurrent
                                      ? FontWeight.w900
                                      : FontWeight.w700,
                                  color: isCurrent
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withOpacity(opacities[position]),
                                ),
                                child: Text(
                                  inRange ? _alphabet[letterIndex] : ' ',
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
