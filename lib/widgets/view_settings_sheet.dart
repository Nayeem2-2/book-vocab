import 'package:flutter/material.dart';

import '../services/view_preferences_service.dart';

class ViewSettingsSheet extends StatefulWidget {
  const ViewSettingsSheet({
    super.key,
    required this.preference,
    required this.onChanged,
    required this.previewBuilder,
    required this.description,
  });

  final BrowseViewPreference preference;
  final ValueChanged<BrowseViewPreference> onChanged;
  final Widget Function(BrowseViewPreference preference) previewBuilder;
  final String description;

  @override
  State<ViewSettingsSheet> createState() => _ViewSettingsSheetState();
}

class _ViewSettingsSheetState extends State<ViewSettingsSheet> {
  late BrowseLayout _layout = widget.preference.layout;
  late int _listSize = widget.preference.listSize;
  late int _gridSize = widget.preference.gridSize;
  int get _size => _layout == BrowseLayout.list ? _listSize : _gridSize;

  BrowseViewPreference get _preference => BrowseViewPreference(
    layout: _layout, listSize: _listSize, gridSize: _gridSize,
  );

  void _update({BrowseLayout? layout, int? size}) {
    setState(() {
      _layout = layout ?? _layout;
      if (size != null) {
        if (_layout == BrowseLayout.list) {
          _listSize = size;
        } else {
          _gridSize = size;
        }
      }
    });
    widget.onChanged(_preference);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Icon(Icons.tune_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'View settings',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(widget.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
              const SizedBox(height: 18),
              const Text('Layout', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 9),
              SegmentedButton<BrowseLayout>(
                segments: const [
                  ButtonSegment(
                    value: BrowseLayout.list,
                    label: Text('List'),
                    icon: Icon(Icons.view_list_rounded),
                  ),
                  ButtonSegment(
                    value: BrowseLayout.grid,
                    label: Text('Grid'),
                    icon: Icon(Icons.grid_view_rounded),
                  ),
                ],
                selected: {_layout},
                onSelectionChanged: (selection) =>
                    _update(layout: selection.first),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  const Expanded(
                    child: Text('Item size',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Text(
                    const ['Compact', 'Small', 'Balanced', 'Large', 'Spacious'][_size - 1],
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              Slider(
                value: _size.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                label: const ['Compact', 'Small', 'Balanced', 'Large', 'Spacious'][_size - 1],
                onChanged: (value) => _update(size: value.round()),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('More items', style: theme.textTheme.labelSmall),
                  Text('Larger cards', style: theme.textTheme.labelSmall),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Text('Live preview',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Text('Updates as you adjust',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: widget.previewBuilder(_preference),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
