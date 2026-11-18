import 'package:flutter/material.dart';

import '../models/book_models.dart';

class PageDetailsInput {
  const PageDetailsInput({
    required this.name,
    required this.pageNumber,
  });

  final String name;
  final int pageNumber;
}

/// Dialog for editing a page's independent display name and page number.
/// Duplicate page numbers are intentionally allowed and shown as a warning.
class PageDetailsDialog extends StatefulWidget {
  const PageDetailsDialog({
    super.key,
    required this.page,
    required this.pages,
  });

  final ChapterData page;
  final List<ChapterData> pages;

  @override
  State<PageDetailsDialog> createState() => _PageDetailsDialogState();
}

class _PageDetailsDialogState extends State<PageDetailsDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _numberController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.page.title);
    _numberController =
        TextEditingController(text: widget.page.pageNumber.toString());
    _nameController.addListener(_refreshNumberWarning);
    _numberController.addListener(_refreshNumberWarning);
  }

  @override
  void dispose() {
    _numberController.removeListener(_refreshNumberWarning);
    _nameController.removeListener(_refreshNumberWarning);
    _nameController.dispose();
    _numberController.dispose();
    super.dispose();
  }

  void _refreshNumberWarning() {
    if (mounted) setState(() {});
  }

  int? get _parsedNumber => int.tryParse(_numberController.text.trim());

  int get _duplicateNumberCount {
    final number = _parsedNumber;
    if (number == null) return 0;
    return widget.pages.where((page) {
      return page.stableId != widget.page.stableId &&
          page.pageNumber == number;
    }).length;
  }

  void _submit() {
    final name = _nameController.text.trim();
    final pageNumber = _parsedNumber;
    if (name.isEmpty || pageNumber == null || pageNumber < 1) return;
    Navigator.of(context).pop(
      PageDetailsInput(name: name, pageNumber: pageNumber),
    );
  }

  @override
  Widget build(BuildContext context) {
    final number = _parsedNumber;
    final invalidNumber = number == null || number < 1;
    final duplicateCount = _duplicateNumberCount;

    return AlertDialog(
      title: const Text('Edit page details'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Page name',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _numberController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Page number',
                  border: const OutlineInputBorder(),
                  errorText: invalidNumber
                      ? 'Enter a positive whole number.'
                      : null,
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (duplicateCount > 0) ...[
                const SizedBox(height: 9),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Color(0xFFB7791F),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        duplicateCount == 1
                            ? 'Another page already uses this number. '
                                'Duplicate page numbers are allowed.'
                            : '$duplicateCount other pages already use this '
                                'number. Duplicate page numbers are allowed.',
                        style: const TextStyle(
                          color: Color(0xFF9A6413),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 7),
              const Text(
                'If the page name is already used, a number such as (1) '
                'or (2) will be added automatically.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: invalidNumber || _nameController.text.trim().isEmpty
              ? null
              : _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
