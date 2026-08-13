import 'package:material_ui/material_ui.dart';

Future<String?> showRenameDialog(
  BuildContext context, {
  required String title,
  required String initialValue,
  required String helperText,
  required Key fieldKey,
  required Key saveKey,
  int? maxLength,
}) => showDialog<String>(
  context: context,
  builder: (context) => _RenameDialog(
    title: title,
    initialValue: initialValue,
    helperText: helperText,
    fieldKey: fieldKey,
    saveKey: saveKey,
    maxLength: maxLength,
  ),
);

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({
    required this.title,
    required this.initialValue,
    required this.helperText,
    required this.fieldKey,
    required this.saveKey,
    this.maxLength,
  });

  final String title;
  final String initialValue;
  final String helperText;
  final Key fieldKey;
  final Key saveKey;
  final int? maxLength;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: widget.fieldKey,
      controller: _controller,
      autofocus: true,
      textInputAction: TextInputAction.done,
      maxLength: widget.maxLength,
      decoration: InputDecoration(
        labelText: 'Name',
        helperText: widget.helperText,
      ),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: widget.saveKey,
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Save'),
      ),
    ],
  );
}
