import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../models/coding_agent_hooks.dart';
import '../../models/settings.dart';
import '../../state/app/app_state.dart';
import '../../state/persistence/stores.dart';
import '../../state/server/coding_agent_hooks_controller.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/top_toast.dart';

part 'terminal_settings_sheet.g.dart';

/// Font size + theme controls (mirrors TerminalSettingsSheet).
@ObservationWidget()
class TerminalSettingsSheet extends _$TerminalSettingsSheet {
  const TerminalSettingsSheet({required this.serverId, super.key});

  final String serverId;

  @override
  Widget build(BuildContext context) {
    final app = ObservationScope.of<AppState>(context);
    final store = app.terminalSettings;
    final s = store.settings;
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
            Padding(
              padding: const EdgeInsets.all(MotifSpacing.sm),
              child: SegmentedButton<TerminalThemeSetting>(
                segments: const [
                  ButtonSegment(
                    value: TerminalThemeSetting.light,
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: TerminalThemeSetting.dark,
                    label: Text('Dark'),
                  ),
                  ButtonSegment(
                    value: TerminalThemeSetting.system,
                    label: Text('System'),
                  ),
                ],
                selected: {s.theme},
                onSelectionChanged: (sel) => store.setTheme(sel.first),
              ),
            ),
          ],
        ),
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
