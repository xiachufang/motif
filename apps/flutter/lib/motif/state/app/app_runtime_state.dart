sealed class AppRuntimeLifecycle {
  const AppRuntimeLifecycle();
}

final class AppRuntimeForeground extends AppRuntimeLifecycle {
  const AppRuntimeForeground();
}

final class AppRuntimeBackground extends AppRuntimeLifecycle {
  const AppRuntimeBackground();
}

sealed class AppStartupState {
  const AppStartupState();
}

final class AppStartupDormant extends AppStartupState {
  const AppStartupDormant();
}

final class AppStartupWaitingEmbedded extends AppStartupState {
  const AppStartupWaitingEmbedded(this.serverId);

  final String serverId;
}

final class AppStartupConnecting extends AppStartupState {
  const AppStartupConnecting(this.serverId);

  final String serverId;
}

final class AppStartupReady extends AppStartupState {
  const AppStartupReady(this.serverId);

  final String? serverId;
}

final class AppStartupFailed extends AppStartupState {
  const AppStartupFailed(this.serverId, this.error);

  final String serverId;
  final Object error;
}

/// Two orthogonal root regions: application lifecycle and startup intent.
final class AppRuntimeState {
  const AppRuntimeState({required this.lifecycle, required this.startup});

  const AppRuntimeState.initial()
    : lifecycle = const AppRuntimeForeground(),
      startup = const AppStartupDormant();

  final AppRuntimeLifecycle lifecycle;
  final AppStartupState startup;

  AppRuntimeState copyWith({
    AppRuntimeLifecycle? lifecycle,
    AppStartupState? startup,
  }) => AppRuntimeState(
    lifecycle: lifecycle ?? this.lifecycle,
    startup: startup ?? this.startup,
  );
}
