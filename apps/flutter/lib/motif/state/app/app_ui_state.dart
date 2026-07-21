import 'package:flutter_observation/flutter_observation.dart';

part 'app_ui_state.g.dart';

/// Desktop top-level view selector: use the client (sessions/terminal) or
/// administer this machine's embedded server.
enum AppViewMode { client, server }

enum AppLifecyclePhase { foreground, background }

/// Request to open a session from an in-app notification / push tap.
final class PendingSessionOpen {
  const PendingSessionOpen({required this.serverId, required this.session});

  final String serverId;
  final String session;
}

@ObservableModel()
class AppShellViewModel extends _$AppShellViewModel {
  AppShellViewModel({
    AppViewMode viewMode = AppViewMode.client,
    AppLifecyclePhase lifecycle = AppLifecyclePhase.foreground,
    PendingSessionOpen? pendingSessionOpen,
    @ObservationReadOnly() required SessionSidebarViewModel sidebar,
  }) : super(viewMode, lifecycle, pendingSessionOpen, sidebar);
}

/// Session workspace chrome shared while switching between live workspaces.
@ObservableModel()
class SessionSidebarViewModel extends _$SessionSidebarViewModel {
  SessionSidebarViewModel({
    bool showSessions = false,
    bool showFileTree = false,
    bool showGitDiff = false,
    bool showBottomBar = false,
    double width = 340,
    double splitFraction = 0.5,
    double firstSplitFraction = 0.34,
    double secondSplitFraction = 0.67,
  }) : super(
         showSessions,
         showFileTree,
         showGitDiff,
         showBottomBar,
         width,
         splitFraction,
         firstSplitFraction,
         secondSplitFraction,
       );

  bool get hasVisiblePanel => showSessions || showFileTree || showGitDiff;
}
