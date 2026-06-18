abstract interface class ServerConnectionRuntime {
  void handleAppPaused(ServerConnectionRuntimeHost host);
  void handleAppResumed(ServerConnectionRuntimeHost host);
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
}
