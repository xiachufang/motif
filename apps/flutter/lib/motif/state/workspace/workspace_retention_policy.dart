abstract interface class WorkspaceRetentionPolicy {
  void handleAppPaused(WorkspaceRetentionHost host);
  void handleAppResumed(WorkspaceRetentionHost host);

  /// When focus switches to another workspace, whether the workspace being
  /// left should stay attached to its session (warm) rather
  /// than detaching. Desktop keeps background workspaces warm for instant
  /// switch-back; mobile detaches to avoid streaming invisible sessions.
  bool get keepSessionWarmOnSwitchAway;

  /// Maximum number of fully retained server/session workspaces. This bounds
  /// live transports, PTY replay buffers, terminal workers, and mounted panes.
  int get maxRetainedWorkspaces;
}

abstract interface class WorkspaceRetentionHost {
  void handleMobileAppPaused();
  void handleMobileAppResumed();
  void reclaimForeground();
}

class MobileWorkspaceRetentionPolicy implements WorkspaceRetentionPolicy {
  const MobileWorkspaceRetentionPolicy();

  @override
  void handleAppPaused(WorkspaceRetentionHost host) {
    host.handleMobileAppPaused();
  }

  @override
  void handleAppResumed(WorkspaceRetentionHost host) {
    host.handleMobileAppResumed();
  }

  @override
  bool get keepSessionWarmOnSwitchAway => false;

  @override
  int get maxRetainedWorkspaces => 1;
}

class DesktopWorkspaceRetentionPolicy implements WorkspaceRetentionPolicy {
  const DesktopWorkspaceRetentionPolicy();

  @override
  void handleAppPaused(WorkspaceRetentionHost host) {
    // Desktop workspaces keep their transport alive while the app/window is not
    // active. Blur/hide is a UI state, not a session lifecycle event.
  }

  @override
  void handleAppResumed(WorkspaceRetentionHost host) {
    host.reclaimForeground();
  }

  @override
  bool get keepSessionWarmOnSwitchAway => true;

  @override
  int get maxRetainedWorkspaces => 4;
}
