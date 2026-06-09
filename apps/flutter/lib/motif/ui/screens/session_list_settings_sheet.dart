import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../log/log.dart';
import '../../log/log_export.dart';
import '../../state/app_state.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/top_toast.dart';

class SessionListSettingsSheet extends StatefulWidget {
  const SessionListSettingsSheet({super.key});

  @override
  State<SessionListSettingsSheet> createState() =>
      _SessionListSettingsSheetState();
}

class _SessionListSettingsSheetState extends State<SessionListSettingsSheet> {
  bool _exporting = false;

  Future<void> _exportLogs() async {
    setState(() => _exporting = true);
    try {
      await Log.flush();
      final result = await exportLogFiles();
      if (!mounted) return;
      showMotifToast(context, 'Logs exported: ${result.path}');
    } catch (e) {
      if (!mounted) return;
      showMotifToast(context, 'Export logs failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final push = app.push;
    final c = context.motif;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MotifSection(
          title: 'Notifications',
          dividerIndent: MotifSpacing.lg,
          children: [
            MotifSectionRow(
              leading: Icon(Icons.notifications_outlined, color: c.accent),
              title: 'Push notifications',
              onTap: () => push.setEnabled(!push.enabled),
              trailing: Switch(value: push.enabled, onChanged: push.setEnabled),
            ),
          ],
        ),
        const SizedBox(height: MotifSpacing.xl),
        MotifSection(
          title: 'Diagnostics',
          children: [
            MotifSectionRow(
              leading: Icon(Icons.file_download_outlined, color: c.accent),
              title: 'Export logs',
              trailing: _exporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.chevron_right, color: c.textTertiary),
              onTap: _exporting ? null : _exportLogs,
            ),
          ],
        ),
      ],
    );
  }
}

Future<void> showSessionListSettingsSheet(BuildContext context) {
  return showAdaptiveModal<void>(
    context,
    builder: (_) => AdaptiveModal(
      title: 'Settings',
      content: const SessionListSettingsSheet(),
    ),
  );
}
