import 'package:flutter/material.dart';

/// Filters and sorts names with exact matches first, then prefix matches,
/// followed by substring matches. Every group is alphabetically ordered.
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

/// A compact A–Z rail that jumps through a sorted list by initial letter.
/// It is deliberately separate from Flutter's ordinary scrollbar: the user
/// drags the alphabet itself, like the fast index in Android contacts apps.
class AlphabetFastScroller extends StatefulWidget {
  const AlphabetFastScroller({
    super.key,
    required this.controller,
    required this.names,
    required this.itemExtent,
  });

  final ScrollController controller;
  final List<String> names;
  final double itemExtent;

  @override
  State<AlphabetFastScroller> createState() => _AlphabetFastScrollerState();
}

class _AlphabetFastScrollerState extends State<AlphabetFastScroller> {
  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  String? _activeLetter;
  double _activeY = 0;

  void _jumpTo(double localY, double railHeight) {
    if (widget.names.isEmpty || !widget.controller.hasClients || railHeight <= 0) {
      return;
    }

    final fraction = (localY / railHeight).clamp(0.0, 0.999999);
    final letterIndex = (fraction * _alphabet.length).floor();
    final letter = _alphabet[letterIndex];

    var targetIndex = -1;
    var smallestForwardGap = 27;
    var closestEarlierLetter = -1;
    var smallestBackwardGap = 27;

    // Search results can be grouped by relevance (prefix matches first), so
    // locate the nearest available initial rather than assuming the whole
    // filtered result is globally alphabetical.
    for (var i = 0; i < widget.names.length; i++) {
      final name = widget.names[i].trim();
      if (name.isEmpty) continue;
      final initial = name[0].toUpperCase();
      final letterPosition = _alphabet.indexOf(initial);
      if (letterPosition < 0) continue;

      final gap = letterPosition - letterIndex;
      if (gap >= 0 && gap < smallestForwardGap) {
        smallestForwardGap = gap;
        targetIndex = i;
      } else if (gap < 0 && -gap < smallestBackwardGap) {
        smallestBackwardGap = -gap;
        closestEarlierLetter = i;
      }
    }

    if (targetIndex < 0) {
      targetIndex = closestEarlierLetter >= 0 ? closestEarlierLetter : 0;
    }

    final position = widget.controller.position;
    final offset = (targetIndex * widget.itemExtent)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    widget.controller.jumpTo(offset);

    setState(() {
      _activeLetter = letter;
      _activeY = localY.clamp(0.0, railHeight - 1).toDouble();
    });
  }

  void _hideBubble() {
    if (_activeLetter != null && mounted) {
      setState(() => _activeLetter = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.names.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final bubbleTop = (_activeY - 22)
            .clamp(0.0, (height - 44).clamp(0.0, height).toDouble())
            .toDouble();
        return Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) =>
                  _jumpTo(details.localPosition.dy, height),
              onVerticalDragStart: (details) =>
                  _jumpTo(details.localPosition.dy, height),
              onVerticalDragUpdate: (details) =>
                  _jumpTo(details.localPosition.dy, height),
              onVerticalDragEnd: (_) => _hideBubble(),
              onTapUp: (_) => _hideBubble(),
              child: SizedBox(
                width: 28,
                height: height,
                child: Column(
                  children: List.generate(
                    _alphabet.length,
                    (index) => Expanded(
                      child: Center(
                        child: Text(
                          _alphabet[index],
                          style: TextStyle(
                            fontSize: 10,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_activeLetter != null)
              Positioned(
                right: 30,
                top: bubbleTop,
                child: IgnorePointer(
                  child: Material(
                    elevation: 5,
                    color: Theme.of(context).colorScheme.primary,
                    shape: const CircleBorder(),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: Text(
                          _activeLetter!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
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
