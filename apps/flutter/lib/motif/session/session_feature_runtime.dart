import 'package:flutter/widgets.dart';

import '../models/coding_agent_hooks.dart';
import '../models/motif_proto.dart';
import '../models/settings.dart';
import '../platform/services.dart';
import '../state/workspace/remote_port/remote_port_controller.dart';
import '../state/workspace/session_attachment.dart';
import '../state/workspace/terminal/terminal_controller.dart';
import '../state/workspace/view/view_controller.dart';
import '../state/workspace/workspace_api.dart';
import '../state/workspace/workspace_view_model.dart';

/// A resource that the Session feature should reveal after opening a
/// workspace. Callers do not need to know about Session's internal view specs.
sealed class SessionOpenTarget {
  const SessionOpenTarget();
}

final class SessionFileTarget extends SessionOpenTarget {
  const SessionFileTarget(this.path);

  final String path;
}

final class SessionDiffTarget extends SessionOpenTarget {
  const SessionDiffTarget(this.path, {this.staged = false});

  final String? path;
  final bool staged;
}

final class SessionImageTarget extends SessionOpenTarget {
  const SessionImageTarget(this.path);

  final String path;
}

final class SessionWorkspaceCapabilities {
  const SessionWorkspaceCapabilities({
    required this.viewModel,
    required this.attachment,
    required this.terminal,
    required this.views,
    required this.workspace,
    required this.remotePorts,
  });

  final WorkspaceViewModel viewModel;
  final SessionAttachment attachment;
  final TerminalController terminal;
  final ViewController views;
  final WorkspaceApi workspace;
  final RemotePortController remotePorts;
}

final class SessionServerGroup {
  const SessionServerGroup({
    required this.id,
    required this.name,
    required this.isReady,
    required this.sessions,
  });

  final String id;
  final String name;
  final bool isReady;
  final List<SessionInfo> sessions;
}

abstract interface class SessionSidebarState {
  bool get showSessions;
  set showSessions(bool value);
  bool get showFileTree;
  set showFileTree(bool value);
  bool get showGitDiff;
  set showGitDiff(bool value);
  bool get showBottomBar;
  set showBottomBar(bool value);
  double get width;
  set width(double value);
  double get splitFraction;
  set splitFraction(double value);
  double get firstSplitFraction;
  set firstSplitFraction(double value);
  double get secondSplitFraction;
  set secondSplitFraction(double value);
}

/// Capabilities supplied to Session by the application composition layer.
///
/// Session owns its UI and workspace behavior; the runtime owns process-wide
/// stores, connected-server catalogs, and platform integrations.
abstract interface class SessionFeatureRuntime {
  bool get keepWorkspaceWarm;
  int get maxRetainedWorkspaces;
  SessionSidebarState get sidebar;
  double get terminalFontSize;
  SpeechService get speech;
  List<SessionServerGroup> get connectedServers;

  SessionWorkspaceCapabilities workspaceCapabilities(
    String serverId,
    String session,
  );

  void retainWorkspace(String serverId, String session);

  void prepareWorkspaceSelection({
    required String fromServerId,
    required String fromSession,
    required String toServerId,
    required String toSession,
  });

  String sessionDisplayName(String serverId, String session);
  Future<void> refreshConnectedSessions();
  Future<void> detachAllSessions();
  Future<void> renameSession(
    String serverId,
    String session,
    String displayName,
  );
  void markCloseShortcutConsumed();

  List<QuickCommand> resolvedCommands(String? runningProgram);
  String? effectiveCommandSetId(String? runningProgram);
  Future<void> openQuickCommandEditor(BuildContext context, {String? setId});
  Future<void> openTerminalSettings(
    BuildContext context, {
    required String serverId,
  });

  bool canCheckCodingAgentHooks(String serverId);
  bool codingAgentHookPromptShown(String serverId, CodingAgent agent);
  Future<bool> claimCodingAgentHookPrompt(String serverId, CodingAgent agent);
  Future<bool> installCodingAgentHook(String serverId, CodingAgent agent);
}
