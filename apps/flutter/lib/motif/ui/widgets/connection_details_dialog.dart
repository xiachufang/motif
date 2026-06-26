import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/connection_state.dart';
import 'top_toast.dart';

bool hasConnectionDetails(ServerConnectionViewState view) {
  if (!view.subtitle.contains('\n')) return false;
  return view.tone == ServerConnectionTone.danger ||
      view.tone == ServerConnectionTone.warning ||
      view.statusLabel.toLowerCase().contains('failed');
}

String connectionStatusSummary(
  ServerConnectionViewState? view, {
  required String fallback,
}) {
  if (view == null) return fallback;
  final lines = _detailLines(view.subtitle);
  if (lines.isEmpty) return fallback;
  if (lines.length == 1) return lines.single;

  final detail = lines.skip(1).toList();
  final summary = <String>[];
  if (detail.isNotEmpty) summary.add(detail.first);

  final exit = detail
      .where((line) => line.startsWith('Exit code:'))
      .firstOrNull;
  if (exit != null) summary.add(exit);

  final stderr = _firstOutputLine(detail, 'stderr:');
  if (stderr != null) {
    summary.add(stderr);
  } else {
    final stdout = _firstOutputLine(detail, 'stdout:');
    if (stdout != null) summary.add(stdout);
  }

  if (summary.isEmpty) return fallback;
  return summary.join('\n');
}

Future<void> showConnectionDetailsDialog(
  BuildContext context, {
  required String title,
  required String detail,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 420),
        child: SingleChildScrollView(
          child: SelectableText(
            detail,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy_outlined, size: 18),
          label: const Text('Copy'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: detail));
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            if (context.mounted) {
              showMotifToast(context, 'Connection details copied');
            }
          },
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

List<String> _detailLines(String value) =>
    value.split('\n').map((line) => line.trim()).where((line) {
      return line.isNotEmpty;
    }).toList();

String? _firstOutputLine(List<String> lines, String marker) {
  final index = lines.indexOf(marker);
  if (index < 0) return null;
  for (final line in lines.skip(index + 1)) {
    if (line == 'stderr:' || line == 'stdout:') break;
    if (line.isNotEmpty) return line;
  }
  return null;
}
