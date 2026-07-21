sealed class DeviceRegistrationRuntimeState {
  const DeviceRegistrationRuntimeState();
}

final class DeviceRegistrationIdle extends DeviceRegistrationRuntimeState {
  const DeviceRegistrationIdle();
}

final class DeviceRegistrationRegistering
    extends DeviceRegistrationRuntimeState {
  const DeviceRegistrationRegistering(this.operationId);

  final int operationId;
}

final class DeviceRegistrationRegistered
    extends DeviceRegistrationRuntimeState {
  const DeviceRegistrationRegistered(this.instanceId);

  final String? instanceId;
}

final class DeviceRegistrationUnregistering
    extends DeviceRegistrationRuntimeState {
  const DeviceRegistrationUnregistering(this.operationId);

  final int operationId;
}

final class DeviceRegistrationFailed extends DeviceRegistrationRuntimeState {
  const DeviceRegistrationFailed({
    required this.operationId,
    required this.error,
    required this.stackTrace,
  });

  final int operationId;
  final Object error;
  final StackTrace stackTrace;
}

final class DeviceRuntimeState {
  const DeviceRuntimeState({
    required this.generation,
    required this.operationSequence,
    required this.registration,
    required this.muteOperationIds,
  });

  const DeviceRuntimeState.initial()
    : generation = 0,
      operationSequence = 0,
      registration = const DeviceRegistrationIdle(),
      muteOperationIds = const {};

  final int generation;
  final int operationSequence;
  final DeviceRegistrationRuntimeState registration;
  final Map<String, int> muteOperationIds;

  Set<String> get mutingSessions => muteOperationIds.keys.toSet();

  DeviceRuntimeState copyWith({
    int? generation,
    int? operationSequence,
    DeviceRegistrationRuntimeState? registration,
    Map<String, int>? muteOperationIds,
  }) => DeviceRuntimeState(
    generation: generation ?? this.generation,
    operationSequence: operationSequence ?? this.operationSequence,
    registration: registration ?? this.registration,
    muteOperationIds: muteOperationIds ?? this.muteOperationIds,
  );
}
