import 'embedded_server_models.dart';

sealed class EmbeddedServerLifecycleState {
  const EmbeddedServerLifecycleState();
}

final class EmbeddedServerUnavailable extends EmbeddedServerLifecycleState {
  const EmbeddedServerUnavailable();
}

final class EmbeddedServerStopped extends EmbeddedServerLifecycleState {
  const EmbeddedServerStopped();
}

final class EmbeddedServerStarting extends EmbeddedServerLifecycleState {
  const EmbeddedServerStarting();
}

final class EmbeddedServerRunning extends EmbeddedServerLifecycleState {
  const EmbeddedServerRunning();
}

final class EmbeddedServerStopping extends EmbeddedServerLifecycleState {
  const EmbeddedServerStopping();
}

final class EmbeddedServerFailed extends EmbeddedServerLifecycleState {
  const EmbeddedServerFailed(this.error);

  final Object error;
}

EmbeddedServerLifecycleState embeddedLifecycleForStatus(
  EmbeddedServerStatus status,
) => switch (status.phase) {
  EmbeddedRunState.stopped => const EmbeddedServerStopped(),
  EmbeddedRunState.starting => const EmbeddedServerStarting(),
  EmbeddedRunState.running => const EmbeddedServerRunning(),
  EmbeddedRunState.failed => EmbeddedServerFailed(
    StateError(status.error ?? 'embedded server failed'),
  ),
};

sealed class EmbeddedServerPollState {
  const EmbeddedServerPollState();
}

final class EmbeddedServerPollDormant extends EmbeddedServerPollState {
  const EmbeddedServerPollDormant();
}

/// A single keyed delay/probe effect is pending. No Timer or in-flight flag is
/// needed in the service itself.
final class EmbeddedServerPollScheduled extends EmbeddedServerPollState {
  const EmbeddedServerPollScheduled(this.sequence);

  final int sequence;
}

sealed class EmbeddedConfigWriteState {
  const EmbeddedConfigWriteState(this.revision);

  final int revision;
}

final class EmbeddedConfigIdle extends EmbeddedConfigWriteState {
  const EmbeddedConfigIdle(super.revision);
}

final class EmbeddedConfigSaving extends EmbeddedConfigWriteState {
  const EmbeddedConfigSaving(super.revision);
}

final class EmbeddedConfigSaveFailed extends EmbeddedConfigWriteState {
  const EmbeddedConfigSaveFailed(super.revision, this.error);

  final Object error;
}

/// Three child regions: native lifecycle, status polling and ordered config
/// persistence. Config/status payloads stay in the projection view model.
final class EmbeddedServerRuntimeState {
  const EmbeddedServerRuntimeState({
    required this.generation,
    required this.requestSequence,
    required this.lifecycle,
    required this.poll,
    required this.configWrite,
  });

  const EmbeddedServerRuntimeState.initial({bool available = false})
    : generation = 0,
      requestSequence = 0,
      lifecycle = available
          ? const EmbeddedServerStopped()
          : const EmbeddedServerUnavailable(),
      poll = const EmbeddedServerPollDormant(),
      configWrite = const EmbeddedConfigIdle(0);

  factory EmbeddedServerRuntimeState.fromStatus({
    required bool available,
    required EmbeddedServerStatus status,
  }) => EmbeddedServerRuntimeState(
    generation: 0,
    requestSequence: 0,
    lifecycle: available
        ? embeddedLifecycleForStatus(status)
        : const EmbeddedServerUnavailable(),
    poll: const EmbeddedServerPollDormant(),
    configWrite: const EmbeddedConfigIdle(0),
  );

  final int generation;
  final int requestSequence;
  final EmbeddedServerLifecycleState lifecycle;
  final EmbeddedServerPollState poll;
  final EmbeddedConfigWriteState configWrite;

  bool get available => lifecycle is! EmbeddedServerUnavailable;

  EmbeddedServerRuntimeState copyWith({
    int? generation,
    int? requestSequence,
    EmbeddedServerLifecycleState? lifecycle,
    EmbeddedServerPollState? poll,
    EmbeddedConfigWriteState? configWrite,
  }) => EmbeddedServerRuntimeState(
    generation: generation ?? this.generation,
    requestSequence: requestSequence ?? this.requestSequence,
    lifecycle: lifecycle ?? this.lifecycle,
    poll: poll ?? this.poll,
    configWrite: configWrite ?? this.configWrite,
  );
}
