import 'package:flutter/material.dart';

import '../../models/coding_agent_hooks.dart';
import '../../models/settings.dart';
import '../../session/session_feature_runtime.dart';
import '../../state/app/app_state.dart';
import '../../state/server/coding_agent_hook_prompt.dart' as hooks;
import '../screens/quick_command_editor.dart';
import '../screens/terminal_settings_sheet.dart';

/// Application-side implementation of the capabilities consumed by Session.
/// This is the only bridge between Session and [AppState].
final class AppSessionRuntime implements SessionFeatureRuntime {
  AppSessionRuntime(this._app) : sidebar = _AppSessionSidebarState(_app);

  final AppState _app;

  @override
  final SessionSidebarState sidebar;

  @override
  bool get keepWorkspaceWarm => _app.keepSessionWarmOnSwitchAway;

  @override
  int get maxRetainedWorkspaces => _app.maxRetainedWorkspaces;

  @override
  double get terminalFontSize => _app.terminalSettings.settings.fontSize;

  @override
  get speech => _app.platform.speech;

  @override
  List<SessionServerGroup> get connectedServers => [
    for (final group in _app.connectedServers)
      SessionServerGroup(
        id: group.profile.id,
        name: group.profile.name,
        isReady: group.access.isReady,
        sessions: group.sessions.sessions.toList(growable: false),
      ),
  ];

  @override
  SessionWorkspaceCapabilities workspaceCapabilities(
    String serverId,
    String session,
  ) {
    final value = _app.workspaceCapabilities(serverId, session);
    return SessionWorkspaceCapabilities(
      viewModel: value.viewModel,
      attachment: value.attachment,
      terminal: value.terminal,
      views: value.views,
      workspace: value.workspace,
      remotePorts: value.remotePorts,
    );
  }

  @override
  void retainWorkspace(String serverId, String session) {
    _app.workspaceForSession(serverId, session);
  }

  @override
  void prepareWorkspaceSelection({
    required String fromServerId,
    required String fromSession,
    required String toServerId,
    required String toSession,
  }) {
    _app.prepareWorkspaceSelection(
      fromServerId: fromServerId,
      fromSession: fromSession,
      toServerId: toServerId,
      toSession: toSession,
    );
  }

  @override
  String sessionDisplayName(String serverId, String session) {
    for (final group in connectedServers) {
      if (group.id != serverId) continue;
      for (final candidate in group.sessions) {
        if (candidate.name == session) return candidate.displayName;
      }
    }
    return session;
  }

  @override
  Future<void> refreshConnectedSessions() => _app.refreshConnectedSessions();

  @override
  Future<void> detachAllSessions() => _app.detachAllSessions();

  @override
  Future<void> renameSession(
    String serverId,
    String session,
    String displayName,
  ) async {
    final server = _app.existingServerInstance(serverId);
    if (server == null) throw StateError('server is not connected');
    await server.sessions.rename(session, displayName);
  }

  @override
  void markCloseShortcutConsumed() => _app.markCloseShortcutConsumed();

  @override
  List<QuickCommand> resolvedCommands(String? runningProgram) =>
      _app.commands.resolved(runningProgram);

  @override
  String? effectiveCommandSetId(String? runningProgram) =>
      _app.commands.effectiveSetId(runningProgram);

  @override
  Future<void> openQuickCommandEditor(BuildContext context, {String? setId}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => QuickCommandEditor(setId: setId),
        ),
      );

  @override
  Future<void> openTerminalSettings(
    BuildContext context, {
    required String serverId,
  }) => showTerminalSettingsSheet(context, serverId: serverId);

  @override
  bool canCheckCodingAgentHooks(String serverId) {
    final server = _app.existingServerInstance(serverId);
    return server != null && server.isLive;
  }

  @override
  bool codingAgentHookPromptShown(String serverId, CodingAgent agent) =>
      _app.terminalSettings.codingAgentHookPromptShown(serverId, agent);

  @override
  Future<bool> claimCodingAgentHookPrompt(
    String serverId,
    CodingAgent agent,
  ) async {
    final server = _app.existingServerInstance(serverId);
    if (server == null || !server.isLive) return false;
    return hooks.claimCodingAgentHookPrompt(
      controller: server.codingAgentHooks,
      promptStore: _app.terminalSettings,
      serverId: serverId,
      agent: agent,
    );
  }

  @override
  Future<bool> installCodingAgentHook(
    String serverId,
    CodingAgent agent,
  ) async {
    final server = _app.existingServerInstance(serverId);
    if (server == null || !server.isLive) return false;
    final status = await server.codingAgentHooks.install(agent);
    return status.configured(agent);
  }
}

final class _AppSessionSidebarState implements SessionSidebarState {
  const _AppSessionSidebarState(this._app);

  final AppState _app;

  @override
  bool get showSessions => _app.sessionSidebar.showSessions;
  @override
  set showSessions(bool value) => _app.sessionSidebar.showSessions = value;
  @override
  bool get showFileTree => _app.sessionSidebar.showFileTree;
  @override
  set showFileTree(bool value) => _app.sessionSidebar.showFileTree = value;
  @override
  bool get showGitDiff => _app.sessionSidebar.showGitDiff;
  @override
  set showGitDiff(bool value) => _app.sessionSidebar.showGitDiff = value;
  @override
  bool get showBottomBar => _app.sessionSidebar.showBottomBar;
  @override
  set showBottomBar(bool value) => _app.sessionSidebar.showBottomBar = value;
  @override
  double get width => _app.sessionSidebar.width;
  @override
  set width(double value) => _app.sessionSidebar.width = value;
  @override
  double get splitFraction => _app.sessionSidebar.splitFraction;
  @override
  set splitFraction(double value) => _app.sessionSidebar.splitFraction = value;
  @override
  double get firstSplitFraction => _app.sessionSidebar.firstSplitFraction;
  @override
  set firstSplitFraction(double value) =>
      _app.sessionSidebar.firstSplitFraction = value;
  @override
  double get secondSplitFraction => _app.sessionSidebar.secondSplitFraction;
  @override
  set secondSplitFraction(double value) =>
      _app.sessionSidebar.secondSplitFraction = value;
}
