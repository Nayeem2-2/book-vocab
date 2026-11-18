import 'package:flutter/material.dart';

/// A compact vertical index for a numerically ordered page list.
///
/// The thumb follows the finger immediately. List navigation is handled by the
/// parent: it can coalesce direct index jumps during dragging and perform one
/// short settling animation when the gesture ends.
class PageNumberFastScroller extends StatefulWidget {
  const PageNumberFastScroller({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.pageNumbers,
    required this.onIndexChanged,
    required this.onDragEnd,
  });

  final ScrollController controller;
  final int itemCount;
  final List<int> pageNumbers;
  final ValueChanged<int> onIndexChanged;
  final ValueChanged<int> onDragEnd;

  @override
  State<PageNumberFastScroller> createState() =>
      _PageNumberFastScrollerState();
}

class _PageNumberFastScrollerState extends State<PageNumberFastScroller> {
  final ValueNotifier<double> _fraction = ValueNotifier<double>(0);
  final ValueNotifier<bool> _dragging = ValueNotifier<bool>(false);
  final ValueNotifier<int?> _activeIndex = ValueNotifier<int?>(null);
  int? _lastSentIndex;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncFromScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFromScroll());
  }

  @override
  void didUpdateWidget(covariant PageNumberFastScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncFromScroll);
      widget.controller.addListener(_syncFromScroll);
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncFromScroll());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromScroll);
    _fraction.dispose();
    _dragging.dispose();
    _activeIndex.dispose();
    super.dispose();
  }

  void _syncFromScroll() {
    if (_dragging.value || !widget.controller.hasClients) return;
    final position = widget.controller.position;
    final maxExtent = position.maxScrollExtent;
    final next = maxExtent <= 0
        ? 0.0
        : (position.pixels / maxExtent).clamp(0.0, 1.0).toDouble();
    if ((next - _fraction.value).abs() > 0.002) {
      _fraction.value = next;
    }
  }

  void _moveTo(double localY, double railHeight) {
    if (widget.itemCount <= 0 || railHeight <= 0) return;
    if (!_dragging.value) _dragging.value = true;

    // Keep the thumb centered under the finger instead of letting its top
    // edge follow the pointer. This makes the rail feel more precise near
    // both ends while preserving immediate thumb response.
    const thumbHeight = 30.0;
    final travel = (railHeight - thumbHeight).clamp(1.0, double.infinity);
    final nextFraction =
        ((localY - thumbHeight / 2) / travel).clamp(0.0, 1.0).toDouble();
    final nextIndex = (nextFraction * (widget.itemCount - 1))
        .round()
        .clamp(0, widget.itemCount - 1)
        .toInt();

    if ((_fraction.value - nextFraction).abs() > 0.001) {
      _fraction.value = nextFraction;
    }
    if (_activeIndex.value != nextIndex) {
      _activeIndex.value = nextIndex;
    }

    if (_lastSentIndex != nextIndex) {
      _lastSentIndex = nextIndex;
      widget.onIndexChanged(nextIndex);
    }
  }

  void _finish() {
    if (!_dragging.value) return;
    final finalIndex = _activeIndex.value;
    _dragging.value = false;
    if (finalIndex != null) widget.onDragEnd(finalIndex);
    _activeIndex.value = null;
    _lastSentIndex = null;
    // The controller listener will now track the short final list animation.
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount <= 1) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (height <= 40) return const SizedBox.shrink();

        return SizedBox(
          width: 38,
          height: height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _moveTo(details.localPosition.dy, height),
            onTapUp: (_) => _finish(),
            onTapCancel: _finish,
            onVerticalDragStart: (details) =>
                _moveTo(details.localPosition.dy, height),
            onVerticalDragUpdate: (details) =>
                _moveTo(details.localPosition.dy, height),
            onVerticalDragEnd: (_) => _finish(),
            onVerticalDragCancel: _finish,
            child: ValueListenableBuilder<double>(
              valueListenable: _fraction,
              builder: (context, fraction, _) =>
                  ValueListenableBuilder<bool>(
                valueListenable: _dragging,
                builder: (context, dragging, __) =>
                    ValueListenableBuilder<int?>(
                  valueListenable: _activeIndex,
                  builder: (context, activeIndex, ___) {
                    const thumbHeight = 30.0;
                    final top = (fraction * (height - thumbHeight))
                        .clamp(0.0, height - thumbHeight)
                        .toDouble();
                    final pageNumber = activeIndex != null &&
                            activeIndex < widget.pageNumbers.length
                        ? widget.pageNumbers[activeIndex]
                        : null;

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          right: 15,
                          top: 4,
                          bottom: 4,
                          child: Container(
                            width: 4,
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withOpacity(dragging ? 0.38 : 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 9,
                          top: top,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 70),
                            curve: Curves.easeOut,
                            width: dragging ? 16 : 12,
                            height: thumbHeight,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary.withOpacity(
                                dragging ? 1 : 0.48,
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        if (dragging && pageNumber != null)
                          Positioned(
                            right: 29,
                            top: (top - 3).clamp(0.0, height - 36).toDouble(),
                            child: Material(
                              elevation: 3,
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(10),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                child: Text(
                                  '$pageNumber',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onPrimary,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
