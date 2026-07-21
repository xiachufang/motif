import 'dart:async';

import '../runtime/runtime_effect.dart';
import '../runtime/runtime_machine.dart';
import 'app_runtime_state.dart';

typedef StartupServerConnector = Future<bool> Function(String serverId);
typedef AppLifecycleEffect = FutureOr<void> Function(bool foreground);

sealed class _AppEvent {
  const _AppEvent();
}

final class _LifecycleRequested extends _AppEvent {
  const _LifecycleRequested(this.foreground);

  final bool foreground;
}

final class _StartupRequested extends _AppEvent {
  const _StartupRequested({
    required this.serverId,
    required this.waitForEmbedded,
  });

  final String? serverId;
  final bool waitForEmbedded;
}

final class _EmbeddedReady extends _AppEvent {
  const _EmbeddedReady(this.serverId);

  final String serverId;
}

final class _StartupCompleted extends _AppEvent {
  const _StartupCompleted(this.serverId, this.connected);

  final String serverId;
  final bool connected;
}

final class _AppEffectFailed extends _AppEvent {
  const _AppEffectFailed(this.effect, this.error);

  final _AppEffect effect;
  final Object error;
}

sealed class _AppEffect implements RuntimeEffect {
  const _AppEffect();
}

final class _ApplyLifecycle extends _AppEffect {
  const _ApplyLifecycle(this.foreground);

  final bool foreground;

  @override
  Object get key => 'app-lifecycle';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _ConnectStartupServer extends _AppEffect {
  const _ConnectStartupServer(this.serverId);

  final String serverId;

  @override
  Object get key => 'app-startup';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

/// Root machine for lifecycle propagation and the one-shot startup intent.
final class AppRuntimeController {
  AppRuntimeController({
    required this.connectStartupServer,
    required this.applyLifecycle,
    required this.onStateChanged,
  }) {
    _machine = RuntimeMachine<AppRuntimeState, _AppEvent, _AppEffect>(
      initialState: const AppRuntimeState.initial(),
      reducer: _reduce,
      execute: _execute,
      mapEffectError: (effect, error, _) => _AppEffectFailed(effect, error),
      onTransition: (transition) {
        onStateChanged(transition.current);
        _settleStartupWaiters(transition.current.startup);
      },
    );
    onStateChanged(_machine.state);
  }

  final StartupServerConnector connectStartupServer;
  final AppLifecycleEffect applyLifecycle;
  final void Function(AppRuntimeState state) onStateChanged;

  late final RuntimeMachine<AppRuntimeState, _AppEvent, _AppEffect> _machine;
  final List<Completer<void>> _startupWaiters = [];

  AppRuntimeState get state => _machine.state;

  Future<void> start({
    required String? serverId,
    required bool waitForEmbedded,
  }) {
    final waiter = Completer<void>();
    _startupWaiters.add(waiter);
    _machine.dispatch(
      _StartupRequested(serverId: serverId, waitForEmbedded: waitForEmbedded),
    );
    _settleStartupWaiters(_machine.state.startup);
    return waiter.future;
  }

  void embeddedReady(String serverId) =>
      _machine.dispatch(_EmbeddedReady(serverId));

  void setForeground(bool foreground) =>
      _machine.dispatch(_LifecycleRequested(foreground));

  RuntimeTransition<AppRuntimeState, _AppEffect> _reduce(
    AppRuntimeState state,
    _AppEvent event,
  ) {
    switch (event) {
      case _LifecycleRequested(:final foreground):
        final lifecycle = foreground
            ? const AppRuntimeForeground()
            : const AppRuntimeBackground();
        if (state.lifecycle.runtimeType == lifecycle.runtimeType) {
          // Platform lifecycle callbacks may repeat. The state is already
          // correct, but consumers such as push registration still need the
          // resume/pause edge to be replayed.
          return RuntimeTransition(
            state,
            effects: [_ApplyLifecycle(foreground)],
          );
        }
        return RuntimeTransition(
          state.copyWith(lifecycle: lifecycle),
          effects: [_ApplyLifecycle(foreground)],
        );
      case _StartupRequested(:final serverId, :final waitForEmbedded):
        if (serverId == null) {
          return RuntimeTransition(
            state.copyWith(startup: const AppStartupReady(null)),
          );
        }
        if (waitForEmbedded) {
          return RuntimeTransition(
            state.copyWith(startup: AppStartupWaitingEmbedded(serverId)),
            invalidateEffects: true,
          );
        }
        return RuntimeTransition(
          state.copyWith(startup: AppStartupConnecting(serverId)),
          effects: [_ConnectStartupServer(serverId)],
        );
      case _EmbeddedReady(:final serverId):
        if (state.startup case AppStartupWaitingEmbedded(
          serverId: final waitingId,
        ) when waitingId == serverId) {
          return RuntimeTransition(
            state.copyWith(startup: AppStartupConnecting(serverId)),
            effects: [_ConnectStartupServer(serverId)],
          );
        }
        return RuntimeTransition(state);
      case _StartupCompleted(:final serverId, :final connected):
        if (state.startup case AppStartupConnecting(
          serverId: final connectingId,
        ) when connectingId == serverId) {
          return RuntimeTransition(
            state.copyWith(
              startup: connected
                  ? AppStartupReady(serverId)
                  : AppStartupFailed(
                      serverId,
                      StateError('startup server did not become ready'),
                    ),
            ),
          );
        }
        return RuntimeTransition(state);
      case _AppEffectFailed(:final effect, :final error):
        if (effect case _ConnectStartupServer(:final serverId)) {
          return RuntimeTransition(
            state.copyWith(startup: AppStartupFailed(serverId, error)),
          );
        }
        return RuntimeTransition(state);
    }
  }

  Future<_AppEvent?> _execute(
    _AppEffect effect,
    RuntimeEffectContext context,
  ) async {
    switch (effect) {
      case _ApplyLifecycle(:final foreground):
        await applyLifecycle(foreground);
        return null;
      case _ConnectStartupServer(:final serverId):
        final connected = await connectStartupServer(serverId);
        if (!context.isCurrent) return null;
        return _StartupCompleted(serverId, connected);
    }
  }

  void _settleStartupWaiters(AppStartupState state) {
    if (state is AppStartupConnecting) return;
    // Waiting for an embedded endpoint is intentionally non-blocking; the
    // endpoint event will resume the machine later.
    for (final waiter in _startupWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _startupWaiters.clear();
  }

  void dispose() {
    _machine.dispose();
    for (final waiter in _startupWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _startupWaiters.clear();
  }
}
