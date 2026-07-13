import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../log/log.dart';
import '../../log/log_export.dart';
import '../../state/app_state.dart';
import '../../update/desktop_update_service.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/desktop_update_dialog.dart';
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
  bool _checkingForUpdate = false;

  Future<void> _exportLogs() async {
    setState(() => _exporting = true);
    try {
      await Log.flush();
      final result = await exportLogFiles();
      if (!mounted) return;
      if (_shouldShareExportedLogs) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(result.path, mimeType: 'text/plain')],
            title: 'Motif logs',
            subject: 'Motif logs',
            sharePositionOrigin: _sharePositionOrigin(),
          ),
        );
        return;
      }
      showMotifToast(context, 'Logs exported: ${result.path}');
    } catch (e) {
      if (!mounted) return;
      showMotifToast(context, 'Export logs failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  bool get _shouldShareExportedLogs {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
  }

  Rect? _sharePositionOrigin() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  Future<void> _checkForUpdates(DesktopUpdateService updater) async {
    setState(() => _checkingForUpdate = true);
    try {
      final result = await updater.checkNow();
      if (!mounted) return;
      final update = result.update;
      if (update != null) {
        await updater.presentUpdate(
          update,
          () => showDesktopUpdateDialog(
            context,
            update,
            onSkipVersion: () => updater.skipVersion(update),
          ),
        );
        return;
      }
      switch (result.status) {
        case DesktopUpdateCheckStatus.upToDate:
          showMotifToast(context, 'Motif is up to date.');
          break;
        case DesktopUpdateCheckStatus.unavailable:
          showMotifToast(
            context,
            'Could not check for updates. Try again later.',
          );
          break;
        case DesktopUpdateCheckStatus.updateAvailable:
          // An available result always carries an update; keep this defensive
          // fallback in case a future release source violates that contract.
          showMotifToast(
            context,
            'Could not check for updates. Try again later.',
          );
          break;
      }
    } finally {
      if (mounted) setState(() => _checkingForUpdate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final updater = context.watch<DesktopUpdateService?>();
    final push = app.push;
    final c = context.motif;
    // The embedded server is configured in the dedicated "Server" view, not
    // here — this sheet is purely client settings.
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
        if (updater != null) ...[
          const SizedBox(height: MotifSpacing.xl),
          MotifSection(
            title: 'Updates',
            children: [
              MotifSectionRow(
                leading: Icon(Icons.system_update_outlined, color: c.accent),
                title: 'Check for updates',
                trailing: _checkingForUpdate
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.chevron_right, color: c.textTertiary),
                onTap: _checkingForUpdate
                    ? null
                    : () => _checkForUpdates(updater),
              ),
            ],
          ),
        ],
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
