import 'package:flutter/material.dart';

/// Filters and sorts names with exact matches first, then prefix matches,
/// followed by substring matches. Results within each relevance group are
/// alphabetically ordered.
bool isEnglishAlphabetLetter(String value) {
  if (value.length != 1) return false;
  final code = value.codeUnitAt(0);
  return code >= 65 && code <= 90;
}

class _RankedName<T> {
  const _RankedName(this.value, this.normalizedName, this.rank, this.sourceIndex);
  final T value;
  final String normalizedName;
  final int rank;
  final int sourceIndex;
}

/// Filters and sorts names with exact matches first, then prefix matches,
/// followed by substring matches. Names are normalized once per item, rather
/// than repeatedly inside the O(n log n) sort comparator.
List<T> rankAndSortByName<T>(
  Iterable<T> values,
  String Function(T value) nameOf,
  String query,
) {
  final normalizedQuery = query.trim().toLowerCase();
  final ranked = <_RankedName<T>>[];
  var sourceIndex = 0;

  for (final value in values) {
    final name = nameOf(value).trim().toLowerCase();
    if (normalizedQuery.isEmpty || name.contains(normalizedQuery)) {
      final rank = normalizedQuery.isEmpty
          ? 0
          : name == normalizedQuery
              ? 0
              : name.startsWith(normalizedQuery)
                  ? 1
                  : 2;
      ranked.add(_RankedName(value, name, rank, sourceIndex));
    }
    sourceIndex++;
  }

  ranked.sort((a, b) {
    final rankDifference = a.rank.compareTo(b.rank);
    if (rankDifference != 0) return rankDifference;
    final nameDifference = a.normalizedName.compareTo(b.normalizedName);
    if (nameDifference != 0) return nameDifference;
    return a.sourceIndex.compareTo(b.sourceIndex);
  });
  return ranked.map((item) => item.value).toList(growable: false);
}

/// Alphabetical fast-scroll rail used by Books, Pages and page vocabulary.
///
/// The rail stays subtly visible when idle. During touch/drag it becomes fully
/// visible and displays a five-letter focal preview around the active letter.
/// For regular lists [itemExtent] maps an alphabet position to a row offset.
/// For grouped/variable-height lists, supply [onLetterSelected] and jump to
/// the indexed section (for example with IndexedScrollController.jumpToIndex).
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

  // Separate listenables keep pointer tracking cheap: moving the bubble does
  // not rebuild the 26-letter rail, and changing a letter does not scroll the
  // list repeatedly for every pointer event within that letter.
  final ValueNotifier<bool> _interacting = ValueNotifier<bool>(false);
  final ValueNotifier<int?> _activeIndex = ValueNotifier<int?>(null);
  final ValueNotifier<double> _activeY = ValueNotifier<double>(0);
  String? _lastNotifiedLetter;

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
    final nextY = localY.clamp(0.0, railHeight - 1).toDouble();

    if (!_interacting.value) _interacting.value = true;
    if (_activeIndex.value != requestedIndex) {
      _activeIndex.value = requestedIndex;
    }
    // The bubble tracks the finger directly; it is deliberately not animated
    // toward each new position, which would make it lag behind fast drags.
    if ((nextY - _activeY.value).abs() >= 0.5) {
      _activeY.value = nextY;
    }

    if (nearestIndex == null) return;
    final selectedName = widget.names[nearestIndex].trim();
    if (selectedName.isEmpty) return;
    final selectedLetter = selectedName[0].toUpperCase();

    // One direct index jump per actual letter transition. No overlapping
    // 100-ms animations are queued while the user is dragging.
    if (selectedLetter == _lastNotifiedLetter) return;
    _lastNotifiedLetter = selectedLetter;

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
    if (!_interacting.value) return;
    _interacting.value = false;
    _activeIndex.value = null;
    _lastNotifiedLetter = null;
  }

  @override
  void dispose() {
    _interacting.dispose();
    _activeIndex.dispose();
    _activeY.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.names.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (height <= 0) return const SizedBox.shrink();

        const bubbleHeight = 126.0;
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
              onVerticalDragCancel: _finishInteraction,
              child: ValueListenableBuilder<bool>(
                valueListenable: _interacting,
                builder: (context, interacting, _) => AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  opacity: interacting ? 1.0 : 0.30,
                  child: SizedBox(
                    width: 26,
                    height: height,
                    child: ValueListenableBuilder<int?>(
                      valueListenable: _activeIndex,
                      builder: (context, activeIndex, _) => Column(
                        children: List.generate(_alphabet.length, (index) {
                          final isActive = interacting && index == activeIndex;
                          return Expanded(
                            child: Center(
                              child: Text(
                                _alphabet[index],
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
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _interacting,
              builder: (context, interacting, _) {
                if (!interacting) return const SizedBox.shrink();
                return ValueListenableBuilder<double>(
                  valueListenable: _activeY,
                  builder: (context, activeY, _) {
                    final bubbleTop = (activeY - bubbleHeight / 2)
                        .clamp(
                          0.0,
                          (height - bubbleHeight)
                              .clamp(0.0, height)
                              .toDouble(),
                        )
                        .toDouble();
                    return ValueListenableBuilder<int?>(
                      valueListenable: _activeIndex,
                      builder: (context, activeIndex, _) {
                        if (activeIndex == null) {
                          return const SizedBox.shrink();
                        }
                        return Positioned(
                          right: 30,
                          top: bubbleTop,
                          child: IgnorePointer(
                            child: Material(
                              elevation: 7,
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(24),
                              child: Container(
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
                                    final inRange = letterIndex >= 0 &&
                                        letterIndex < _alphabet.length;
                                    final isCurrent = distance == 0;
                                    const sizes = [10.0, 15.0, 29.0, 15.0, 10.0];
                                    const opacities = [0.28, 0.55, 1.0, 0.55, 0.28];

                                    return SizedBox(
                                      height: 23,
                                      child: Center(
                                        child: Text(
                                          inRange ? _alphabet[letterIndex] : ' ',
                                          style: TextStyle(
                                            fontSize: sizes[position],
                                            height: 1,
                                            fontWeight: isCurrent
                                                ? FontWeight.w900
                                                : FontWeight.w700,
                                            color: isCurrent
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                : Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withOpacity(opacities[position]),
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ],
        );
      },
    );
  }
}
