import 'package:flutter/material.dart';

import '../../models/motif_proto.dart';
import '../../state/motif_client.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/top_toast.dart';

Future<SessionInfo?> createSessionWithDialog(
  BuildContext context,
  MotifClient motif,
) async {
  final result = await showAdaptiveModal<(String, String)>(
    context,
    builder: (_) => const _CreateSessionDialog(),
  );
  if (result == null) return null;
  try {
    return await motif.createSession(result.$1, result.$2);
  } catch (e) {
    if (context.mounted) {
      showMotifToast(context, 'Create failed: $e');
    }
    return null;
  }
}

class _CreateSessionDialog extends StatefulWidget {
  const _CreateSessionDialog();

  @override
  State<_CreateSessionDialog> createState() => _CreateSessionDialogState();
}

class _CreateSessionDialogState extends State<_CreateSessionDialog> {
  final _name = TextEditingController();
  final _workdir = TextEditingController(text: '~');

  @override
  void dispose() {
    _name.dispose();
    _workdir.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveModal(
      title: 'New session',
      content: MotifSection(
        title: 'Session',
        dividerIndent: MotifSpacing.lg,
        children: [
          _sectionField(
            controller: _name,
            label: 'Name',
            onChanged: (_) => setState(() {}),
          ),
          _sectionField(controller: _workdir, label: 'Working directory'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _name.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (
                  _name.text.trim(),
                  _workdir.text.trim(),
                )),
          child: const Text('Create'),
        ),
      ],
    );
  }

  Widget _sectionField({
    required TextEditingController controller,
    required String label,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      child: TextField(
        controller: controller,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          isDense: true,
        ),
        onChanged: onChanged,
      ),
    );
  }
}
