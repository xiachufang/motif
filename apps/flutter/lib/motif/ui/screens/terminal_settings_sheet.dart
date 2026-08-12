import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../models/coding_agent_hooks.dart';
import '../../models/settings.dart';
import '../../net/ssh/ssh_bootstrapper.dart';
import '../../state/app/app_state.dart';
import '../../state/persistence/stores.dart';
import '../../state/server/coding_agent_hooks_controller.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/top_toast.dart';

part 'terminal_settings_sheet.g.dart';

typedef SshMotifdVersionLoader =
    Future<SshMotifdVersionInfo> Function(MotifServer server);
typedef SshMotifdUpdater = Future<void> Function(MotifServer server);

/// Terminal-specific appearance and integration controls.
@ObservationWidget()
class TerminalSettingsSheet extends _$TerminalSettingsSheet {
  const TerminalSettingsSheet({
    required this.serverId,
    this.sshMotifdVersionLoader,
    this.sshMotifdUpdater,
    super.key,
  });

  final String serverId;
  final SshMotifdVersionLoader? sshMotifdVersionLoader;
  final SshMotifdUpdater? sshMotifdUpdater;

  @override
  Widget build(BuildContext context) {
    final app = ObservationScope.of<AppState>(context);
    final store = app.terminalSettings;
    final s = store.settings;
    final server = app.serverById(serverId);
    final hooks = app.existingServerInstance(serverId)?.codingAgentHooks;
    final c = context.motif;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MotifSection(
          title: 'Appearance',
          dividerIndent: MotifSpacing.lg,
          children: [
            MotifSectionRow(
              title: 'Font size',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: s.fontSize > TerminalSettings.minFontSize
                        ? () => store.setFontSize(s.fontSize - 1)
                        : null,
                  ),
                  Text(
                    '${s.fontSize.toStringAsFixed(0)} pt',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontFeatures: const [],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: s.fontSize < TerminalSettings.maxFontSize
                        ? () => store.setFontSize(s.fontSize + 1)
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (server?.kind == ServerKind.ssh) ...[
          const SizedBox(height: MotifSpacing.md),
          _SshMotifdUpdateSection(
            server: server!,
            versionLoader: sshMotifdVersionLoader,
            updater: sshMotifdUpdater,
          ),
        ],
        if (hooks != null) ...[
          const SizedBox(height: MotifSpacing.md),
          _CodingAgentHooksSection(
            controller: hooks,
            promptStore: store,
            serverId: serverId,
          ),
        ],
      ],
    );
  }
}

class _SshMotifdUpdateSection extends StatefulWidget {
  const _SshMotifdUpdateSection({
    required this.server,
    this.versionLoader,
    this.updater,
  });

  final MotifServer server;
  final SshMotifdVersionLoader? versionLoader;
  final SshMotifdUpdater? updater;

  @override
  State<_SshMotifdUpdateSection> createState() =>
      _SshMotifdUpdateSectionState();
}

class _SshMotifdUpdateSectionState extends State<_SshMotifdUpdateSection> {
  SshMotifdVersionInfo? _version;
  String? _error;
  bool _checking = false;
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  void didUpdateWidget(covariant _SshMotifdUpdateSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server != widget.server) unawaited(_check());
  }

  Future<SshMotifdVersionInfo> _loadVersion() {
    final loader = widget.versionLoader;
    return loader == null
        ? SshBootstrapper(server: widget.server).checkForUpdate()
        : loader(widget.server);
  }

  Future<void> _check() async {
    if (_checking || _updating) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final version = await _loadVersion();
      if (!mounted) return;
      setState(() {
        _version = version;
        _checking = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = _friendlyVersionError(error);
      });
    }
  }

  Future<void> _update() async {
    final version = _version;
    if (version == null || !version.updateAvailable || _updating) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Update remote motifd?'),
        content: Text(
          'The SSH server will update to motifd '
          '${version.availableVersion} and restart. Current remote terminal '
          'connections may be interrupted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      final updater = widget.updater;
      if (updater == null) {
        await SshBootstrapper(server: widget.server).upgradeMotifd();
      } else {
        await updater(widget.server);
      }
      final refreshed = await _loadVersion();
      if (!mounted) return;
      setState(() {
        _version = refreshed;
        _updating = false;
      });
      showMotifToast(
        context,
        'motifd ${refreshed.serverVersion ?? refreshed.availableVersion} updated',
      );
    } catch (error) {
      if (!mounted) return;
      final message = _friendlyVersionError(error);
      setState(() {
        _updating = false;
        _error = message;
      });
      showMotifToast(context, message, duration: const Duration(seconds: 4));
    }
  }

  static String _friendlyVersionError(Object error) {
    final firstLine = '$error'.trim().split('\n').first;
    return firstLine.isEmpty ? 'Version check failed' : firstLine;
  }

  String get _subtitle {
    if (_updating) {
      return 'Downloading, verifying, and restarting remote motifd…';
    }
    if (_checking) return 'Checking server and local versions…';
    if (_error != null) return _error!;
    final version = _version;
    if (version == null) return 'Version has not been checked.';
    final parts = <String>[
      'Server ${version.serverVersion ?? 'not installed'}',
      'Local ${version.localVersion}',
    ];
    if (version.availableVersion != version.localVersion) {
      parts.add('Available ${version.availableVersion}');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final version = _version;
    final busy = _checking || _updating;
    final Widget trailing;
    if (busy) {
      trailing = SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
      );
    } else if (version?.updateAvailable ?? false) {
      trailing = TextButton(
        key: const ValueKey('update-ssh-motifd'),
        onPressed: _update,
        child: Text(version!.serverVersion == null ? 'Install' : 'Update'),
      );
    } else {
      trailing = IconButton(
        key: const ValueKey('check-ssh-motifd'),
        tooltip: 'Check motifd version',
        onPressed: _check,
        icon: const Icon(Icons.refresh, size: 18),
      );
    }
    return MotifSection(
      title: 'Remote motifd',
      footer:
          'Available only for SSH terminals. Updates use the verified stable release for the server platform.',
      children: [
        MotifSectionRow(
          leading: const Icon(Icons.system_update_alt_outlined, size: 18),
          title: 'motifd version',
          subtitle: _subtitle,
          subtitleColor: _error == null ? null : c.danger,
          trailing: trailing,
          minHeight: 64,
        ),
      ],
    );
  }
}

class _CodingAgentHooksSection extends StatefulWidget {
  const _CodingAgentHooksSection({
    required this.controller,
    required this.promptStore,
    required this.serverId,
  });

  final CodingAgentHooksController controller;
  final TerminalSettingsStore promptStore;
  final String serverId;

  @override
  State<_CodingAgentHooksSection> createState() =>
      _CodingAgentHooksSectionState();
}

class _CodingAgentHooksSectionState extends State<_CodingAgentHooksSection> {
  CodingAgentHooksStatus? _status;
  CodingAgent? _busyAgent;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final status = await widget.controller.status();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _setHook(CodingAgent agent, {required bool install}) async {
    if (_busyAgent != null) return;
    setState(() {
      _busyAgent = agent;
      _error = null;
    });
    try {
      await widget.promptStore.markCodingAgentHookPromptShown(
        widget.serverId,
        agent,
      );
      final status = install
          ? await widget.controller.install(agent)
          : await widget.controller.uninstall(agent);
      if (!mounted) return;
      setState(() => _status = status);
      showMotifToast(
        context,
        install
            ? '${agent.label} hook installed'
            : '${agent.label} hook removed',
      );
    } catch (error) {
      if (!mounted) return;
      final message = _friendlyError(error);
      setState(() => _error = message);
      showMotifToast(context, message, duration: const Duration(seconds: 4));
    } finally {
      if (mounted) setState(() => _busyAgent = null);
    }
  }

  String _friendlyError(Object error) =>
      error.toString().replaceFirst(RegExp(r'^(Bad state|Exception):\s*'), '');

  Widget _agentRow(CodingAgent agent, MotifColors c) {
    final status = _status;
    final configured = status?.configured(agent) == true;
    final busy = _busyAgent == agent;
    final subtitle =
        _error ??
        (status == null
            ? 'Checking…'
            : configured
            ? 'Installed'
            : 'Not installed');
    return MotifSectionRow(
      leading: Icon(Icons.integration_instructions_outlined, color: c.accent),
      title: agent.label,
      subtitle: subtitle,
      subtitleColor: _error == null ? null : c.danger,
      trailing: busy
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
            )
          : TextButton(
              key: ValueKey(
                '${configured ? 'remove' : 'install'}-${agent.name}-hook',
              ),
              onPressed: status == null || _busyAgent != null
                  ? null
                  : () => unawaited(_setHook(agent, install: !configured)),
              style: configured
                  ? TextButton.styleFrom(foregroundColor: c.danger)
                  : null,
              child: Text(configured ? 'Remove' : 'Install'),
            ),
      minHeight: 64,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return MotifSection(
      title: 'Coding agent hooks',
      footer:
          'Hooks only send notifications from Motif terminals. Codex may ask you to review the hook once in /hooks.',
      children: [for (final agent in CodingAgent.values) _agentRow(agent, c)],
    );
  }
}

Future<void> showTerminalSettingsSheet(
  BuildContext context, {
  required String serverId,
}) {
  return showAdaptiveModal<void>(
    context,
    builder: (_) => AdaptiveModal(
      title: 'Terminal',
      content: TerminalSettingsSheet(serverId: serverId),
    ),
  );
}
