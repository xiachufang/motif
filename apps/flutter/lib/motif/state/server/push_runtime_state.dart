sealed class PushServerRegistrationState {
  const PushServerRegistrationState();
}

final class PushServerIdle extends PushServerRegistrationState {
  const PushServerIdle();
}

final class PushServerRegistering extends PushServerRegistrationState {
  const PushServerRegistering({this.previousDeviceToken});

  final String? previousDeviceToken;
}

final class PushServerRegistered extends PushServerRegistrationState {
  const PushServerRegistered({required this.deviceToken, this.instanceId});

  final String deviceToken;
  final String? instanceId;
}

final class PushServerUnregistering extends PushServerRegistrationState {
  const PushServerUnregistering({required this.deviceToken});

  final String deviceToken;
}

final class PushServerRegistrationFailed extends PushServerRegistrationState {
  const PushServerRegistrationFailed(this.error, {this.deviceToken});

  final Object error;
  final String? deviceToken;
}

final class PushServerRuntimeState {
  const PushServerRuntimeState({
    required this.live,
    required this.registration,
  });

  final bool live;
  final PushServerRegistrationState registration;

  PushServerRuntimeState copyWith({
    bool? live,
    PushServerRegistrationState? registration,
  }) => PushServerRuntimeState(
    live: live ?? this.live,
    registration: registration ?? this.registration,
  );
}

sealed class PushHandlerState {
  const PushHandlerState();
}

final class PushHandlersDormant extends PushHandlerState {
  const PushHandlersDormant();
}

final class PushHandlersWiring extends PushHandlerState {
  const PushHandlersWiring();
}

final class PushHandlersReady extends PushHandlerState {
  const PushHandlersReady();
}

final class PushRuntimeState {
  const PushRuntimeState({
    required this.generation,
    required this.enabled,
    required this.handlers,
    required this.servers,
    required this.serverIdsByInstanceId,
  });

  const PushRuntimeState.initial()
    : generation = 0,
      enabled = false,
      handlers = const PushHandlersDormant(),
      servers = const {},
      serverIdsByInstanceId = const {};

  final int generation;
  final bool enabled;
  final PushHandlerState handlers;
  final Map<String, PushServerRuntimeState> servers;
  final Map<String, String> serverIdsByInstanceId;

  PushRuntimeState copyWith({
    int? generation,
    bool? enabled,
    PushHandlerState? handlers,
    Map<String, PushServerRuntimeState>? servers,
    Map<String, String>? serverIdsByInstanceId,
  }) => PushRuntimeState(
    generation: generation ?? this.generation,
    enabled: enabled ?? this.enabled,
    handlers: handlers ?? this.handlers,
    servers: servers ?? this.servers,
    serverIdsByInstanceId: serverIdsByInstanceId ?? this.serverIdsByInstanceId,
  );
}
