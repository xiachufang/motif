import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:share_plus/share_plus.dart';

import '../../log/log.dart';
import '../../log/log_export.dart';
import '../../platform/macos_permissions.dart';
import '../../state/app/app_state.dart';
import '../../update/desktop_update_service.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/desktop_update_dialog.dart';
import '../widgets/motif_form.dart';
import '../widgets/observation_select.dart';
import '../widgets/top_toast.dart';

class SessionListSettingsSheet extends StatefulWidget {
  const SessionListSettingsSheet({
    super.key,
    this.macosPermissions = const MethodChannelMacosPermissions(),
  });

  final MacosPermissions macosPermissions;

  @override
  State<SessionListSettingsSheet> createState() =>
      _SessionListSettingsSheetState();
}

class _SessionListSettingsSheetState extends State<SessionListSettingsSheet>
    with WidgetsBindingObserver {
  bool _exporting = false;
  bool _checkingForUpdate = false;
  bool _loadingPermissions = true;
  MacosPermissionStatuses _permissionStatuses = const {};
  final Set<MacosPermission> _requestingPermissions = {};

  bool get _isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isMacOS) {
      unawaited(_refreshPermissions());
    } else {
      _loadingPermissions = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isMacOS) {
      unawaited(_refreshPermissions());
    }
  }

  Future<void> _refreshPermissions() async {
    if (!_isMacOS) return;
    if (mounted) setState(() => _loadingPermissions = true);
    try {
      final statuses = await widget.macosPermissions.getStatuses();
      if (!mounted) return;
      setState(() => _permissionStatuses = statuses);
    } catch (e) {
      if (!mounted) return;
      showMotifToast(context, 'Could not load macOS permissions: $e');
    } finally {
      if (mounted) setState(() => _loadingPermissions = false);
    }
  }

  Future<void> _requestPermission(MacosPermission permission) async {
    setState(() => _requestingPermissions.add(permission));
    try {
      final status =
          permission == MacosPermission.fullDiskAccess ||
              permission == MacosPermission.automation
          ? await _openPermissionSettings(permission)
          : await widget.macosPermissions.request(permission);
      if (!mounted || status == null) return;
      setState(
        () =>
            _permissionStatuses = {..._permissionStatuses, permission: status},
      );
    } catch (e) {
      if (!mounted) return;
      showMotifToast(context, 'Could not update macOS permission: $e');
    } finally {
      if (mounted) {
        setState(() => _requestingPermissions.remove(permission));
      }
    }
  }

  Future<MacosPermissionStatus?> _openPermissionSettings(
    MacosPermission permission,
  ) async {
    await widget.macosPermissions.openSystemSettings(permission);
    return _permissionStatuses[permission] ??
        MacosPermissionStatus.managedExternally;
  }

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
  Widget build(BuildContext context) => ObservationSelect<Object?>(
    selector: () => null,
    builder: (context, _, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final app = ObservationScope.of<AppState>(context);
    final updater = ObservationScope.of<DesktopUpdateService?>(context);
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
        if (_isMacOS) ...[
          const SizedBox(height: MotifSpacing.xl),
          _buildPermissionsSection(context),
        ],
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

  Widget _buildPermissionsSection(BuildContext context) {
    final c = context.motif;
    return MotifSection(
      title: 'Permissions',
      footer:
          'Permissions are controlled by macOS Privacy & Security settings.',
      headerTrailing: IconButton(
        key: const ValueKey('refresh-macos-permissions'),
        tooltip: 'Refresh permissions',
        visualDensity: VisualDensity.compact,
        onPressed: _loadingPermissions ? null : _refreshPermissions,
        icon: _loadingPermissions
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.refresh, color: c.textSecondary, size: 18),
      ),
      children: [
        _permissionRow(
          permission: MacosPermission.fullDiskAccess,
          icon: Icons.folder_outlined,
          title: 'Full Disk Access',
        ),
        _permissionRow(
          permission: MacosPermission.screenRecording,
          icon: Icons.screen_share_outlined,
          title: 'Screen Recording',
        ),
        _permissionRow(
          permission: MacosPermission.accessibility,
          icon: Icons.accessibility_new,
          title: 'Accessibility',
        ),
        _permissionRow(
          permission: MacosPermission.automation,
          icon: Icons.settings_remote_outlined,
          title: 'Automation',
        ),
      ],
    );
  }

  Widget _permissionRow({
    required MacosPermission permission,
    required IconData icon,
    required String title,
  }) {
    final c = context.motif;
    final status =
        _permissionStatuses[permission] ??
        (_loadingPermissions
            ? MacosPermissionStatus.unavailable
            : permission == MacosPermission.fullDiskAccess ||
                  permission == MacosPermission.automation
            ? MacosPermissionStatus.managedExternally
            : MacosPermissionStatus.unavailable);
    final requesting = _requestingPermissions.contains(permission);
    final statusText = switch (status) {
      MacosPermissionStatus.granted => 'Allowed',
      MacosPermissionStatus.notGranted => 'Not allowed',
      MacosPermissionStatus.managedExternally => 'Managed in System Settings',
      MacosPermissionStatus.unavailable =>
        _loadingPermissions ? 'Checking…' : 'Unavailable',
    };
    final actionText = status == MacosPermissionStatus.notGranted
        ? 'Allow'
        : 'Open Settings';

    return MotifSectionRow(
      leading: Icon(icon, color: c.accent),
      title: title,
      subtitle: statusText,
      trailing: requesting
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : status == MacosPermissionStatus.granted
          ? Icon(Icons.check_circle, color: c.success, size: 20)
          : TextButton(
              key: ValueKey('macos-permission-${permission.wireName}'),
              onPressed: _loadingPermissions
                  ? null
                  : () => _requestPermission(permission),
              child: Text(actionText),
            ),
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
