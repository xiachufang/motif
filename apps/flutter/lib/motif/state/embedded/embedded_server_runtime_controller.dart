import 'dart:async';

import '../runtime/runtime_effect.dart';
import '../runtime/runtime_machine.dart';
import 'embedded_server_models.dart';
import 'embedded_server_runtime_state.dart';

typedef EmbeddedNativeCommand =
    Future<EmbeddedServerStatus> Function(RuntimeEffectContext context);
typedef EmbeddedStatusProbe =
    Future<EmbeddedServerStatus?> Function(RuntimeEffectContext context);
typedef EmbeddedConfigWriter =
    Future<EmbeddedServerConfig> Function(
      EmbeddedServerConfig config,
      RuntimeEffectContext context,
    );
typedef EmbeddedRuntimeProjection =
    void Function(
      EmbeddedServerRuntimeState state, {
      EmbeddedServerStatus? status,
      EmbeddedServerConfig? config,
    });

sealed class _EmbeddedEvent {
  const _EmbeddedEvent();
}

final class _StartRequested extends _EmbeddedEvent {
  const _StartRequested(this.commandId);

  final int commandId;
}

final class _StopRequested extends _EmbeddedEvent {
  const _StopRequested(this.commandId);

  final int commandId;
}

final class _StartCompleted extends _EmbeddedEvent {
  const _StartCompleted(this.commandId, this.status);

  final int commandId;
  final EmbeddedServerStatus status;
}

final class _StopCompleted extends _EmbeddedEvent {
  const _StopCompleted(this.commandId, this.status);

  final int commandId;
  final EmbeddedServerStatus status;
}

final class _StatusPolled extends _EmbeddedEvent {
  const _StatusPolled(this.status);

  final EmbeddedServerStatus? status;
}

final class _ConfigWriteRequested extends _EmbeddedEvent {
  const _ConfigWriteRequested(this.revision, this.config);

  final int revision;
  final EmbeddedServerConfig config;
}

final class _ConfigWritten extends _EmbeddedEvent {
  const _ConfigWritten(this.revision, this.config);

  final int revision;
  final EmbeddedServerConfig config;
}

final class _EmbeddedEffectFailed extends _EmbeddedEvent {
  const _EmbeddedEffectFailed(this.effect, this.error, this.stackTrace);

  final _EmbeddedEffect effect;
  final Object error;
  final StackTrace stackTrace;
}

sealed class _EmbeddedEffect implements RuntimeEffect {
  const _EmbeddedEffect();
}

sealed class _EmbeddedLifecycleEffect extends _EmbeddedEffect {
  const _EmbeddedLifecycleEffect(this.commandId);

  final int commandId;

  @override
  Object get key => 'embedded-lifecycle';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _StartNative extends _EmbeddedLifecycleEffect {
  const _StartNative(super.commandId);
}

final class _StopNative extends _EmbeddedLifecycleEffect {
  const _StopNative(super.commandId);
}

sealed class _EmbeddedPollEffect extends _EmbeddedEffect {
  const _EmbeddedPollEffect();

  @override
  Object get key => 'embedded-poll';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _PollStatus extends _EmbeddedPollEffect {
  const _PollStatus(this.delay);

  final Duration delay;
}

final class _CancelPoll extends _EmbeddedPollEffect {
  const _CancelPoll();
}

final class _WriteConfig extends _EmbeddedEffect {
  const _WriteConfig(this.revision, this.config);

  final int revision;
  final EmbeddedServerConfig config;

  @override
  Object get key => 'embedded-config';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.serial;
}

/// Control node for the desktop embedded server. Native FFI ownership and the
/// raw status cache are injected resources, never state-tree payloads.
final class EmbeddedServerRuntimeController {
  EmbeddedServerRuntimeController({
    required bool available,
    required this.startNative,
    required this.stopNative,
    required this.probeStatus,
    required this.writeConfig,
    required this.project,
    this.pollInterval = const Duration(seconds: 2),
  }) {
    _machine =
        RuntimeMachine<
          EmbeddedServerRuntimeState,
          _EmbeddedEvent,
          _EmbeddedEffect
        >(
          initialState: EmbeddedServerRuntimeState.initial(
            available: available,
          ),
          reducer: _reduce,
          execute: _execute,
          mapEffectError: (effect, error, stackTrace) =>
              _EmbeddedEffectFailed(effect, error, stackTrace),
          onTransition: _onTransition,
        );
    project(_machine.state);
  }

  final EmbeddedNativeCommand startNative;
  final EmbeddedNativeCommand stopNative;
  final EmbeddedStatusProbe probeStatus;
  final EmbeddedConfigWriter writeConfig;
  final EmbeddedRuntimeProjection project;
  final Duration pollInterval;

  late final RuntimeMachine<
    EmbeddedServerRuntimeState,
    _EmbeddedEvent,
    _EmbeddedEffect
  >
  _machine;
  final Map<int, Completer<void>> _commandWaiters = {};
  final Map<int, Completer<void>> _configWaiters = {};

  EmbeddedServerRuntimeState get state => _machine.state;

  Future<void> start() {
    if (!state.available ||
        state.lifecycle is EmbeddedServerStarting ||
        state.lifecycle is EmbeddedServerRunning) {
      return Future<void>.value();
    }
    final id = state.requestSequence + 1;
    final waiter = Completer<void>();
    _commandWaiters[id] = waiter;
    _machine.dispatch(_StartRequested(id));
    return waiter.future;
  }

  Future<void> stop() {
    if (!state.available ||
        state.lifecycle is EmbeddedServerStopped ||
        state.lifecycle is EmbeddedServerStopping) {
      return Future<void>.value();
    }
    final id = state.requestSequence + 1;
    final waiter = Completer<void>();
    _commandWaiters[id] = waiter;
    _machine.dispatch(_StopRequested(id));
    return waiter.future;
  }

  Future<void> updateConfig(EmbeddedServerConfig config) {
    final revision = state.configWrite.revision + 1;
    final waiter = Completer<void>();
    _configWaiters[revision] = waiter;
    _machine.dispatch(_ConfigWriteRequested(revision, config));
    return waiter.future;
  }

  RuntimeTransition<EmbeddedServerRuntimeState, _EmbeddedEffect> _reduce(
    EmbeddedServerRuntimeState state,
    _EmbeddedEvent event,
  ) {
    switch (event) {
      case _StartRequested(:final commandId):
        if (!state.available) return RuntimeTransition(state);
        return RuntimeTransition(
          state.copyWith(
            generation: state.generation + 1,
            requestSequence: commandId,
            lifecycle: const EmbeddedServerStarting(),
            poll: const EmbeddedServerPollDormant(),
          ),
          effects: [_CancelPoll(), _StartNative(commandId)],
        );
      case _StopRequested(:final commandId):
        if (!state.available) return RuntimeTransition(state);
        return RuntimeTransition(
          state.copyWith(
            generation: state.generation + 1,
            requestSequence: commandId,
            lifecycle: const EmbeddedServerStopping(),
            poll: const EmbeddedServerPollDormant(),
          ),
          effects: [_CancelPoll(), _StopNative(commandId)],
        );
      case _StartCompleted(:final status):
        return _statusTransition(state, status);
      case _StopCompleted(:final status):
        return _statusTransition(state, status);
      case _StatusPolled(:final status):
        if (state.poll is! EmbeddedServerPollScheduled) {
          return RuntimeTransition(state);
        }
        final lifecycle = status == null
            ? state.lifecycle
            : embeddedLifecycleForStatus(status);
        return _scheduleOrStopPolling(state.copyWith(lifecycle: lifecycle));
      case _ConfigWriteRequested(:final revision, :final config):
        return RuntimeTransition(
          state.copyWith(configWrite: EmbeddedConfigSaving(revision)),
          effects: [_WriteConfig(revision, config)],
        );
      case _ConfigWritten(:final revision):
        if (state.configWrite.revision != revision) {
          return RuntimeTransition(state);
        }
        return RuntimeTransition(
          state.copyWith(configWrite: EmbeddedConfigIdle(revision)),
        );
      case _EmbeddedEffectFailed(:final effect, :final error):
        if (effect case _WriteConfig(:final revision)) {
          if (state.configWrite.revision != revision) {
            return RuntimeTransition(state);
          }
          return RuntimeTransition(
            state.copyWith(
              configWrite: EmbeddedConfigSaveFailed(revision, error),
            ),
          );
        }
        if (effect is _EmbeddedLifecycleEffect) {
          return RuntimeTransition(
            state.copyWith(
              lifecycle: EmbeddedServerFailed(error),
              poll: const EmbeddedServerPollDormant(),
            ),
          );
        }
        if (effect is _PollStatus) {
          return _scheduleOrStopPolling(state);
        }
        return RuntimeTransition(state);
    }
  }

  RuntimeTransition<EmbeddedServerRuntimeState, _EmbeddedEffect>
  _statusTransition(
    EmbeddedServerRuntimeState state,
    EmbeddedServerStatus status,
  ) => _scheduleOrStopPolling(
    state.copyWith(lifecycle: embeddedLifecycleForStatus(status)),
  );

  RuntimeTransition<EmbeddedServerRuntimeState, _EmbeddedEffect>
  _scheduleOrStopPolling(EmbeddedServerRuntimeState state) {
    final shouldPoll =
        state.lifecycle is EmbeddedServerStarting ||
        state.lifecycle is EmbeddedServerRunning;
    if (!shouldPoll) {
      return RuntimeTransition(
        state.copyWith(poll: const EmbeddedServerPollDormant()),
      );
    }
    final sequence = switch (state.poll) {
      EmbeddedServerPollScheduled(:final sequence) => sequence + 1,
      _ => 1,
    };
    return RuntimeTransition(
      state.copyWith(poll: EmbeddedServerPollScheduled(sequence)),
      effects: [_PollStatus(pollInterval)],
    );
  }

  Future<_EmbeddedEvent?> _execute(
    _EmbeddedEffect effect,
    RuntimeEffectContext context,
  ) async {
    switch (effect) {
      case _StartNative(:final commandId):
        final status = await startNative(context);
        return context.isCurrent ? _StartCompleted(commandId, status) : null;
      case _StopNative(:final commandId):
        final status = await stopNative(context);
        return context.isCurrent ? _StopCompleted(commandId, status) : null;
      case _PollStatus(:final delay):
        if (!await context.delay(delay)) return null;
        final status = await probeStatus(context);
        return context.isCurrent ? _StatusPolled(status) : null;
      case _CancelPoll():
        return null;
      case _WriteConfig(:final revision, :final config):
        final applied = await writeConfig(config, context);
        return context.isCurrent ? _ConfigWritten(revision, applied) : null;
    }
  }

  void _onTransition(
    RuntimeTransitionRecord<EmbeddedServerRuntimeState, _EmbeddedEvent>
    transition,
  ) {
    EmbeddedServerStatus? status;
    EmbeddedServerConfig? config;
    final event = transition.event;
    if (event is _StartCompleted) {
      status = event.status;
    } else if (event is _StopCompleted) {
      status = event.status;
    } else if (event is _StatusPolled) {
      status = event.status;
    } else if (event is _ConfigWritten) {
      config = event.config;
    }
    project(transition.current, status: status, config: config);

    if (event is _StartRequested) {
      _completeSupersededCommands(event.commandId);
    } else if (event is _StopRequested) {
      _completeSupersededCommands(event.commandId);
    } else if (event is _StartCompleted) {
      _commandWaiters.remove(event.commandId)?.complete();
    } else if (event is _StopCompleted) {
      _commandWaiters.remove(event.commandId)?.complete();
    } else if (event is _ConfigWritten) {
      _configWaiters.remove(event.revision)?.complete();
    } else if (event is _EmbeddedEffectFailed) {
      final effect = event.effect;
      if (effect is _EmbeddedLifecycleEffect) {
        _commandWaiters
            .remove(effect.commandId)
            ?.completeError(event.error, event.stackTrace);
      } else if (effect is _WriteConfig) {
        _configWaiters
            .remove(effect.revision)
            ?.completeError(event.error, event.stackTrace);
      }
    }
  }

  void _completeSupersededCommands(int currentId) {
    for (final id in _commandWaiters.keys.toList()) {
      if (id == currentId) continue;
      _commandWaiters.remove(id)?.complete();
    }
  }

  void dispose() {
    _machine.dispose();
    for (final waiter in [
      ..._commandWaiters.values,
      ..._configWaiters.values,
    ]) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _commandWaiters.clear();
    _configWaiters.clear();
  }
}
