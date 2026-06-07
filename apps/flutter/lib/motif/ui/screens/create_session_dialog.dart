import 'package:flutter/material.dart';

import '../../models/motif_proto.dart';
import '../../state/motif_client.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Create failed: $e')));
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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: MotifSpacing.lg),
          TextField(
            controller: _workdir,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Working directory'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
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
}
