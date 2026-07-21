import 'dart:async';

import '../runtime/runtime_effect.dart';
import '../runtime/runtime_machine.dart';
import 'tailscale_models.dart';
import 'tailscale_runtime_state.dart';

typedef TailscaleProgressSink = void Function(TailscaleState state);
typedef TailscaleNodeStarter =
    Future<TailscaleState> Function(
      String? authKey,
      RuntimeEffectContext context,
      TailscaleProgressSink onProgress,
    );
typedef TailscaleNodeStopper =
    Future<void> Function(RuntimeEffectContext context);
typedef TailscaleHealthProbe =
    Future<TailscaleHealthSample?> Function(RuntimeEffectContext context);

final class TailscaleHealthSample {
  const TailscaleHealthSample({required this.state, this.backendState});

  final TailscaleState state;
  final String? backendState;
}

sealed class _TailscaleEvent {
  const _TailscaleEvent();
}

final class _StartRequested extends _TailscaleEvent {
  const _StartRequested(this.authKey);

  final String? authKey;
}

final class _StopRequested extends _TailscaleEvent {
  const _StopRequested();
}

final class _NodeProgress extends _TailscaleEvent {
  const _NodeProgress(this.state);

  final TailscaleState state;
}

final class _NodeStarted extends _TailscaleEvent {
  const _NodeStarted(this.state);

  final TailscaleState state;
}

final class _NodeStopped extends _TailscaleEvent {
  const _NodeStopped();
}

final class _HealthChecked extends _TailscaleEvent {
  const _HealthChecked(this.sample);

  final TailscaleHealthSample? sample;
}

final class _TailscaleEffectFailed extends _TailscaleEvent {
  const _TailscaleEffectFailed(this.effect, this.error);

  final _TailscaleEffect effect;
  final Object error;
}

sealed class _TailscaleEffect implements RuntimeEffect {
  const _TailscaleEffect();
}

sealed class _NodeEffect extends _TailscaleEffect {
  const _NodeEffect();

  @override
  Object get key => 'tailscale-node';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _StartNode extends _NodeEffect {
  const _StartNode(this.authKey);

  final String? authKey;
}

final class _RestartNode extends _NodeEffect {
  const _RestartNode();
}

final class _StopNode extends _NodeEffect {
  const _StopNode();
}

sealed class _HealthEffect extends _TailscaleEffect {
  const _HealthEffect();

  @override
  Object get key => 'tailscale-health';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _ProbeHealth extends _HealthEffect {
  const _ProbeHealth(this.delay);

  final Duration delay;
}

final class _CancelHealth extends _HealthEffect {
  const _CancelHealth();
}

/// Owns all Tailscale control and concurrency state. FFI handles, credentials,
/// HTTP clients and loopback proxy data remain in the service resource layer.
final class TailscaleRuntimeController {
  TailscaleRuntimeController({
    required this.startNode,
    required this.stopNode,
    required this.probeHealth,
    required this.restartAuthKey,
    required this.onStateChanged,
    this.healthProbeInterval = const Duration(seconds: 5),
    this.maxMissedHealthProbes = 2,
    this.maxConsecutiveDegradedProbes = 4,
    this.autoRestartMinInterval = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _machine =
        RuntimeMachine<
          TailscaleRuntimeState,
          _TailscaleEvent,
          _TailscaleEffect
        >(
          initialState: const TailscaleRuntimeState.initial(),
          reducer: _reduce,
          execute: _execute,
          mapEffectError: (effect, error, _) => effect is _ProbeHealth
              ? const _HealthChecked(null)
              : _TailscaleEffectFailed(effect, error),
          onTransition: (transition) {
            onStateChanged(transition.current);
            _settleWaiters(transition.current);
          },
        );
    onStateChanged(_machine.state);
  }

  final TailscaleNodeStarter startNode;
  final TailscaleNodeStopper stopNode;
  final TailscaleHealthProbe probeHealth;
  final String? Function() restartAuthKey;
  final void Function(TailscaleRuntimeState state) onStateChanged;
  final Duration healthProbeInterval;
  final int maxMissedHealthProbes;
  final int maxConsecutiveDegradedProbes;
  final Duration autoRestartMinInterval;
  final DateTime Function() _now;

  late final RuntimeMachine<
    TailscaleRuntimeState,
    _TailscaleEvent,
    _TailscaleEffect
  >
  _machine;
  final List<Completer<void>> _startWaiters = [];
  final List<Completer<void>> _stopWaiters = [];

  TailscaleRuntimeState get state => _machine.state;

  Future<void> start({String? authKey}) {
    final normalized = authKey == null || authKey.isEmpty ? null : authKey;
    final lifecycle = state.lifecycle;
    final mayReplaceAuth =
        normalized != null && lifecycle is TailscaleLifecycleNeedsAuth;
    if (!mayReplaceAuth &&
        (lifecycle is TailscaleLifecycleRunning ||
            lifecycle is TailscaleLifecycleStarting ||
            lifecycle is TailscaleLifecycleNeedsAuth ||
            lifecycle is TailscaleLifecycleRestarting ||
            lifecycle is TailscaleLifecycleStopping)) {
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _startWaiters.add(waiter);
    _machine.dispatch(_StartRequested(normalized));
    _settleWaiters(state);
    return waiter.future;
  }

  Future<void> stop() {
    if (state.lifecycle is TailscaleLifecycleStopped) {
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _stopWaiters.add(waiter);
    _machine.dispatch(const _StopRequested());
    _settleWaiters(state);
    return waiter.future;
  }

  RuntimeTransition<TailscaleRuntimeState, _TailscaleEffect> _reduce(
    TailscaleRuntimeState state,
    _TailscaleEvent event,
  ) {
    switch (event) {
      case _StartRequested(:final authKey):
        return RuntimeTransition(
          state.copyWith(
            generation: state.generation + 1,
            lifecycle: TailscaleLifecycleStarting(
              const TailscaleState(TailscaleStatus.starting),
            ),
            health: const TailscaleHealthDormant(),
            hasSavedAuthKey:
                state.hasSavedAuthKey || (authKey?.isNotEmpty ?? false),
          ),
          effects: [_CancelHealth(), _StartNode(authKey)],
        );
      case _StopRequested():
        return RuntimeTransition(
          state.copyWith(
            generation: state.generation + 1,
            lifecycle: const TailscaleLifecycleStopping(),
            health: const TailscaleHealthDormant(),
          ),
          effects: const [_CancelHealth(), _StopNode()],
        );
      case _NodeProgress(state: final progress):
        if (state.lifecycle
            case TailscaleLifecycleStarting() ||
                TailscaleLifecycleRestarting() ||
                TailscaleLifecycleNeedsAuth(operationPending: true)) {
          return RuntimeTransition(
            state.copyWith(lifecycle: _progressLifecycle(progress)),
          );
        }
        return RuntimeTransition(state);
      case _NodeStarted(state: final visible):
        final lifecycle = tailscaleStableLifecycle(visible);
        final monitor = visible.status == TailscaleStatus.running;
        return RuntimeTransition(
          state.copyWith(
            lifecycle: lifecycle,
            health: monitor
                ? const TailscaleHealthMonitoring()
                : const TailscaleHealthDormant(),
          ),
          effects: [if (monitor) const _ProbeHealth(Duration.zero)],
        );
      case _NodeStopped():
        return RuntimeTransition(
          state.copyWith(
            lifecycle: const TailscaleLifecycleStopped(),
            health: const TailscaleHealthDormant(),
          ),
        );
      case _HealthChecked(:final sample):
        final health = state.health;
        if (health is! TailscaleHealthMonitoring) {
          return RuntimeTransition(state);
        }
        var missed = health.missedProbes;
        var degraded = health.consecutiveDegradedProbes;
        var backend = health.lastBackendState;
        var lifecycle = state.lifecycle;
        if (sample == null) {
          missed++;
          if (missed >= maxMissedHealthProbes) {
            degraded++;
            lifecycle = const TailscaleLifecycleDegraded(
              TailscaleState(
                TailscaleStatus.degraded,
                detail: 'Tailscale status probe failed.',
              ),
            );
          }
        } else {
          missed = 0;
          backend = sample.backendState;
          lifecycle = tailscaleStableLifecycle(sample.state);
          degraded = sample.state.status == TailscaleStatus.degraded
              ? degraded + 1
              : 0;
        }

        final now = _now();
        final lastRestart = state.lastAutoRestartAt;
        final restartAllowed =
            lastRestart == null ||
            now.difference(lastRestart) >= autoRestartMinInterval;
        if (degraded >= maxConsecutiveDegradedProbes && restartAllowed) {
          return RuntimeTransition(
            state.copyWith(
              generation: state.generation + 1,
              lifecycle: const TailscaleLifecycleRestarting(),
              health: const TailscaleHealthDormant(),
              lastAutoRestartAt: now,
            ),
            effects: const [_CancelHealth(), _RestartNode()],
          );
        }
        return RuntimeTransition(
          state.copyWith(
            lifecycle: lifecycle,
            health: TailscaleHealthMonitoring(
              missedProbes: missed,
              consecutiveDegradedProbes: degraded,
              lastBackendState: backend,
            ),
          ),
          effects: [_ProbeHealth(healthProbeInterval)],
        );
      case _TailscaleEffectFailed(:final effect, :final error):
        if (effect is _NodeEffect) {
          return RuntimeTransition(
            state.copyWith(
              lifecycle: TailscaleLifecycleFailed(error),
              health: const TailscaleHealthDormant(),
            ),
          );
        }
        return RuntimeTransition(state);
    }
  }

  Future<_TailscaleEvent?> _execute(
    _TailscaleEffect effect,
    RuntimeEffectContext context,
  ) async {
    switch (effect) {
      case _StartNode(:final authKey):
        final result = await startNode(authKey, context, (progress) {
          if (context.isCurrent) {
            _machine.dispatch(_NodeProgress(progress));
          }
        });
        return context.isCurrent ? _NodeStarted(result) : null;
      case _RestartNode():
        await stopNode(context);
        if (!context.isCurrent) return null;
        final result = await startNode(restartAuthKey(), context, (progress) {
          if (context.isCurrent) {
            _machine.dispatch(_NodeProgress(progress));
          }
        });
        return context.isCurrent ? _NodeStarted(result) : null;
      case _StopNode():
        await stopNode(context);
        return context.isCurrent ? const _NodeStopped() : null;
      case _ProbeHealth(:final delay):
        if (!await context.delay(delay)) return null;
        final sample = await probeHealth(context);
        return context.isCurrent ? _HealthChecked(sample) : null;
      case _CancelHealth():
        return null;
    }
  }

  TailscaleLifecycleState _progressLifecycle(TailscaleState state) =>
      state.status == TailscaleStatus.needsAuth
      ? TailscaleLifecycleNeedsAuth(state, operationPending: true)
      : TailscaleLifecycleStarting(state);

  void _settleWaiters(TailscaleRuntimeState state) {
    if (!state.nodeOperationPending) {
      for (final waiter in _startWaiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _startWaiters.clear();
    }
    if (state.lifecycle is TailscaleLifecycleStopped ||
        state.lifecycle is TailscaleLifecycleFailed) {
      for (final waiter in _stopWaiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _stopWaiters.clear();
    }
  }

  void dispose() {
    _machine.dispose();
    for (final waiter in [..._startWaiters, ..._stopWaiters]) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _startWaiters.clear();
    _stopWaiters.clear();
  }
}
