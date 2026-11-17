import 'package:flutter/material.dart';

/// A name-entry dialog that owns its TextEditingController for the full
/// lifetime of the dialog route, including the reverse transition after pop.
///
/// Keeping the controller inside this State avoids disposing it while the
/// TextField may still be mounted in the Navigator's overlay.
class NameInputDialog extends StatefulWidget {
  const NameInputDialog({
    super.key,
    required this.title,
    required this.label,
    required this.submitLabel,
    this.initialValue = '',
    this.hintText,
  });

  final String title;
  final String label;
  final String submitLabel;
  final String initialValue;
  final String? hintText;

  @override
  State<NameInputDialog> createState() => _NameInputDialogState();
}

class _NameInputDialogState extends State<NameInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text);
  }

  @override
  void dispose() {
    // This runs when the dialog subtree is actually removed, after its
    // closing transition, rather than immediately when showDialog returns.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hintText,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}
