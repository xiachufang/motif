abstract interface class ServerConnectionRuntime {
  void handleAppPaused(ServerConnectionRuntimeHost host);
  void handleAppResumed(ServerConnectionRuntimeHost host);

  /// When the focused workspace switches to another server, whether the server
  /// being switched away from should stay attached to its session (warm) rather
  /// than detaching. Desktop keeps background workspaces warm for instant
  /// switch-back; mobile detaches to avoid streaming invisible sessions.
  bool get keepSessionWarmOnSwitchAway;
}

abstract interface class ServerConnectionRuntimeHost {
  void handleMobileAppPaused();
  void handleMobileAppResumed();
  void reclaimForeground();
}

class MobileServerConnectionRuntime implements ServerConnectionRuntime {
  const MobileServerConnectionRuntime();

  @override
  void handleAppPaused(ServerConnectionRuntimeHost host) {
    host.handleMobileAppPaused();
  }

  @override
  void handleAppResumed(ServerConnectionRuntimeHost host) {
    host.handleMobileAppResumed();
  }

  @override
  bool get keepSessionWarmOnSwitchAway => false;
}

class DesktopServerConnectionRuntime implements ServerConnectionRuntime {
  const DesktopServerConnectionRuntime();

  @override
  void handleAppPaused(ServerConnectionRuntimeHost host) {
    // Desktop workspaces keep their transport alive while the app/window is not
    // active. Blur/hide is a UI state, not a session lifecycle event.
  }

  @override
  void handleAppResumed(ServerConnectionRuntimeHost host) {
    host.reclaimForeground();
  }

  @override
  bool get keepSessionWarmOnSwitchAway => true;
}
