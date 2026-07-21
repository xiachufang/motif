import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../log/log.dart';
import '../../models/settings.dart';
import '../connection/connection_state.dart';
import '../platform/tailscale_view_model.dart';
import '../runtime/runtime_effect.dart';
import '../runtime/runtime_machine.dart';
import '../server/transport_resolver.dart';
import 'connection/workspace_connection_controller.dart';
import 'connection/workspace_connection_view_model.dart';
import 'workspace_retention_policy.dart';
import 'workspace_runtime_state.dart';

sealed class _WorkspaceEvent {
  const _WorkspaceEvent();
}

final class _ConnectRequested extends _WorkspaceEvent {
  const _ConnectRequested({required this.force});

  final bool force;
}

final class _DisconnectRequested extends _WorkspaceEvent {
  const _DisconnectRequested();
}

final class _ForegroundRequested extends _WorkspaceEvent {
  const _ForegroundRequested(this.foreground);

  final bool foreground;
}

final class _AppPaused extends _WorkspaceEvent {
  const _AppPaused();
}

final class _AppResumed extends _WorkspaceEvent {
  const _AppResumed(this.blocker, {required this.shouldSuspend});

  final ConnectionBlocker? blocker;
  final bool shouldSuspend;
}

final class _TransportAvailabilityChanged extends _WorkspaceEvent {
  const _TransportAvailabilityChanged({
    required this.blocker,
    required this.shouldSuspend,
  });

  final ConnectionBlocker? blocker;
  final bool shouldSuspend;
}

final class _TransportFailure extends _WorkspaceEvent {
  const _TransportFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace? stackTrace;
}

final class _ConnectionChanged extends _WorkspaceEvent {
  const _ConnectionChanged({
    required this.status,
    required this.transportAvailable,
    required this.serverKind,
  });

  final WorkspaceConnectionStatus status;
  final bool transportAvailable;
  final ServerKind serverKind;
}

final class _RouteResolved extends _WorkspaceEvent {
  const _RouteResolved({
    required this.generation,
    required this.resolution,
    required this.force,
    required this.reconnect,
    required this.attempt,
    required this.promotion,
    required this.shouldSuspend,
  });

  final int generation;
  final TransportResolution resolution;
  final bool force;
  final bool reconnect;
  final int attempt;
  final bool promotion;
  final bool shouldSuspend;
}

final class _TransportEstablished extends _WorkspaceEvent {
  const _TransportEstablished({
    required this.generation,
    required this.status,
    required this.transportAvailable,
    required this.promoteRendezvous,
    required this.serverKind,
  });

  final int generation;
  final WorkspaceConnectionStatus status;
  final bool transportAvailable;
  final bool promoteRendezvous;
  final ServerKind serverKind;
}

final class _RetryDue extends _WorkspaceEvent {
  const _RetryDue({required this.generation, required this.attempt});

  final int generation;
  final int attempt;
}

final class _DisconnectCompleted extends _WorkspaceEvent {
  const _DisconnectCompleted({required this.generation});

  final int generation;
}

final class _SuspendCompleted extends _WorkspaceEvent {
  const _SuspendCompleted({required this.generation});

  final int generation;
}

final class _WorkspaceEffectFailed extends _WorkspaceEvent {
  const _WorkspaceEffectFailed({
    required this.effect,
    required this.error,
    required this.stackTrace,
  });

  final _WorkspaceEffect effect;
  final Object error;
  final StackTrace stackTrace;
}

sealed class _WorkspaceEffect implements RuntimeEffect {
  const _WorkspaceEffect({required this.generation});

  final int generation;
}

final class _ResolveRoute extends _WorkspaceEffect {
  const _ResolveRoute({
    required super.generation,
    required this.force,
    required this.reconnect,
    required this.attempt,
    required this.promotion,
  });

  final bool force;
  final bool reconnect;
  final int attempt;
  final bool promotion;

  @override
  Object get key => 'workspace-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _EstablishTransport extends _WorkspaceEffect {
  const _EstablishTransport({
    required super.generation,
    required this.ready,
    required this.force,
    required this.reconnect,
    required this.promotion,
  });

  final TransportReady ready;
  final bool force;
  final bool reconnect;
  final bool promotion;

  @override
  Object get key => 'workspace-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _RecoverTransport extends _WorkspaceEffect {
  const _RecoverTransport({
    required super.generation,
    required this.attempt,
    required this.delay,
    this.markLostMessage,
  });

  final int attempt;
  final Duration delay;
  final String? markLostMessage;

  @override
  Object get key => 'workspace-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _DisconnectTransport extends _WorkspaceEffect {
  const _DisconnectTransport({required super.generation});

  @override
  Object get key => 'workspace-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _SuspendTransport extends _WorkspaceEffect {
  const _SuspendTransport({required super.generation, required this.reason});

  final String reason;

  @override
  Object get key => 'workspace-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _SetForeground extends _WorkspaceEffect {
  const _SetForeground({required super.generation, required this.foreground});

  final bool foreground;

  @override
  Object get key => 'workspace-foreground';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

/// Hierarchical runtime node for one fixed `(serverId, session)` workspace.
///
/// The machine is authoritative for connection intent, focus/app activity,
/// route resolution, retry and blocking. [WorkspaceConnectionController]
/// remains the resource adapter that owns RpcClient and feature controllers.
final class WorkspaceLifecycleController implements WorkspaceRetentionHost {
  static const Duration _reconnectBaseDelay = Duration(milliseconds: 500);
  static const Duration _reconnectMaxDelay = Duration(seconds: 30);

  WorkspaceLifecycleController({
    required this.serverId,
    required this.connection,
    required this.serverProvider,
    required this.resolver,
    WorkspaceRetentionPolicy? retentionPolicy,
  }) : retentionPolicy =
           retentionPolicy ?? const MobileWorkspaceRetentionPolicy() {
    final initialStatus = connection.state;
    final initialTransportAvailable = connection.connection.transportAvailable;
    final initialState = WorkspaceRuntimeState(
      generation: 0,
      activity: const WorkspaceActivityForeground(),
      link: switch (initialStatus) {
        ConnAttached(:final session) when initialTransportAvailable =>
          WorkspaceLinkAttached(session),
        ConnConnected() when initialTransportAvailable =>
          const WorkspaceLinkReady(),
        _ => const WorkspaceLinkDisconnected(),
      },
    );
    _machine =
        RuntimeMachine<
          WorkspaceRuntimeState,
          _WorkspaceEvent,
          _WorkspaceEffect
        >(
          initialState: initialState,
          reducer: _reduce,
          execute: _execute,
          mapEffectError: (effect, error, stackTrace) => _WorkspaceEffectFailed(
            effect: effect,
            error: error,
            stackTrace: stackTrace,
          ),
          onTransition: _onTransition,
        );
    _connectionListener = handleConnectionStateChanged;
    connection.onRuntimeStatusChanged = _connectionListener;
    _project(_machine.state);
  }

  final String serverId;
  final WorkspaceConnectionController connection;
  final MotifServer? Function() serverProvider;
  final TransportResolver resolver;
  final WorkspaceRetentionPolicy retentionPolicy;

  late final RuntimeMachine<
    WorkspaceRuntimeState,
    _WorkspaceEvent,
    _WorkspaceEffect
  >
  _machine;
  late final VoidCallback _connectionListener;
  final List<Completer<void>> _operationWaiters = [];
  final List<Completer<void>> _disconnectWaiters = [];

  WorkspaceRuntimeState get runtimeState => _machine.state;
  bool get wantsConnection => runtimeState.wantsConnection;

  Future<void> connect({bool force = false}) {
    final waiter = Completer<void>();
    _operationWaiters.add(waiter);
    _machine.dispatch(_ConnectRequested(force: force));
    _settleWaiters();
    return waiter.future;
  }

  Future<void> disconnect() {
    final waiter = Completer<void>();
    _disconnectWaiters.add(waiter);
    _machine.dispatch(const _DisconnectRequested());
    _settleWaiters();
    return waiter.future;
  }

  /// Explicit focus transition used when an instance moves between the active
  /// and warm branches of the workspace registry.
  void setForeground(bool foreground) =>
      _machine.dispatch(_ForegroundRequested(foreground));

  /// Resource adapter notification. No Observation subscription is required;
  /// connection mutations become ordinary events in the parent node.
  bool handleConnectionStateChanged() {
    if (_machine.isDisposed) return false;
    final previous = _machine.state;
    final serverKind = serverProvider()?.kind ?? ServerKind.direct;
    _machine.dispatch(
      _ConnectionChanged(
        status: connection.state,
        transportAvailable: connection.connection.transportAvailable,
        serverKind: serverKind,
      ),
    );
    return !identical(previous, _machine.state);
  }

  void handleTailscaleState(TailscaleState _) {
    final server = serverProvider();
    if (server == null || server.kind != ServerKind.tailscale) return;
    _machine.dispatch(
      _TransportAvailabilityChanged(
        blocker: resolver.currentBlocker(server),
        shouldSuspend: connection.isLive || connection.hasTerminalSnapshot,
      ),
    );
  }

  void handleAppPaused() => retentionPolicy.handleAppPaused(this);

  void handleAppResumed() => retentionPolicy.handleAppResumed(this);

  @override
  void handleMobileAppPaused() => _machine.dispatch(const _AppPaused());

  @override
  void handleMobileAppResumed() {
    final server = serverProvider();
    _machine.dispatch(
      _AppResumed(
        server == null ? null : resolver.currentBlocker(server),
        shouldSuspend: connection.isLive || connection.hasTerminalSnapshot,
      ),
    );
  }

  @override
  void reclaimForeground() => setForeground(true);

  void handleTransportFailure(Object error, [StackTrace? stackTrace]) {
    Log.w(
      'workspace transport failed; dispatching recovery server=$serverId',
      name: 'motif.reconnect',
      error: error,
      stackTrace: stackTrace,
    );
    _machine.dispatch(_TransportFailure(error, stackTrace));
  }

  void dispose() {
    if (identical(connection.onRuntimeStatusChanged, _connectionListener)) {
      connection.onRuntimeStatusChanged = null;
    }
    _machine.dispose();
    for (final waiter in [..._operationWaiters, ..._disconnectWaiters]) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _operationWaiters.clear();
    _disconnectWaiters.clear();
    unawaited(resolver.stopForwarder(serverId));
    resolver.forgetRzvDirect(serverId);
  }

  RuntimeTransition<WorkspaceRuntimeState, _WorkspaceEffect> _reduce(
    WorkspaceRuntimeState state,
    _WorkspaceEvent event,
  ) {
    if (event is _DisconnectRequested) {
      final generation = state.generation + 1;
      return RuntimeTransition(
        state.copyWith(
          generation: generation,
          link: const WorkspaceLinkDisconnecting(),
        ),
        invalidateEffects: true,
        effects: [_DisconnectTransport(generation: generation)],
      );
    }

    if (event is _ConnectRequested) {
      if (!event.force &&
          (state.link is WorkspaceLinkOnline ||
              state.link is WorkspaceLinkSynchronizing)) {
        return RuntimeTransition(state);
      }
      if (state.activity is WorkspaceActivityPaused) {
        return RuntimeTransition(
          state.copyWith(
            generation: state.generation + 1,
            link: WorkspaceLinkResolving(
              attempt: 0,
              reconnect: event.force || state.wantsConnection,
              session: _attachedSession(state.link),
              force: event.force,
            ),
          ),
          invalidateEffects: true,
        );
      }
      return _beginResolve(
        state,
        force: event.force,
        reconnect: event.force || state.wantsConnection,
        attempt: event.force ? 0 : _attempt(state.link),
      );
    }

    if (event case _ForegroundRequested(:final foreground)) {
      final activity = foreground
          ? const WorkspaceActivityForeground()
          : const WorkspaceActivityBackground();
      return RuntimeTransition(
        state.copyWith(activity: activity),
        effects: [
          _SetForeground(generation: state.generation, foreground: foreground),
        ],
      );
    }

    if (event is _AppPaused) {
      return RuntimeTransition(
        state.copyWith(activity: const WorkspaceActivityPaused()),
        invalidateEffects: true,
        effects: [
          _SetForeground(generation: state.generation, foreground: false),
        ],
      );
    }

    if (event case _AppResumed(:final blocker, :final shouldSuspend)) {
      final foreground = const WorkspaceActivityForeground();
      if (!state.wantsConnection) {
        return RuntimeTransition(
          state.copyWith(activity: foreground),
          effects: [
            _SetForeground(generation: state.generation, foreground: true),
          ],
        );
      }
      if (blocker != null) {
        return RuntimeTransition(
          state.copyWith(
            activity: foreground,
            link: WorkspaceLinkBlocked(
              blocker: blocker,
              session: _attachedSession(state.link),
            ),
          ),
          invalidateEffects: true,
          effects: [
            _SetForeground(generation: state.generation, foreground: true),
            if (shouldSuspend)
              _SuspendTransport(
                generation: state.generation,
                reason: blocker.message,
              ),
          ],
        );
      }
      return _beginResolve(
        state.copyWith(activity: foreground),
        force: true,
        reconnect: true,
        attempt: _attempt(state.link),
        extraEffects: [
          _SetForeground(generation: state.generation + 1, foreground: true),
        ],
      );
    }

    if (event case _TransportAvailabilityChanged(
      :final blocker,
      :final shouldSuspend,
    )) {
      if (!state.wantsConnection) return RuntimeTransition(state);
      if (blocker != null) {
        return RuntimeTransition(
          state.copyWith(
            link: WorkspaceLinkBlocked(
              blocker: blocker,
              session: _attachedSession(state.link),
            ),
          ),
          invalidateEffects: true,
          effects: [
            if (shouldSuspend)
              _SuspendTransport(
                generation: state.generation,
                reason: blocker.message,
              ),
          ],
        );
      }
      if (state.link is WorkspaceLinkBlocked &&
          state.activity is! WorkspaceActivityPaused) {
        return _beginResolve(state, force: true, reconnect: true, attempt: 0);
      }
      return RuntimeTransition(state);
    }

    if (event case _TransportFailure(:final error)) {
      if (!state.wantsConnection || state.activity is WorkspaceActivityPaused) {
        return RuntimeTransition(state);
      }
      return _recover(
        state,
        error,
        immediate: true,
        markLostMessage: 'workspace transport failed: $error',
      );
    }

    if (event is _ConnectionChanged) {
      return _reduceConnectionChanged(state, event);
    }

    if (event is _RouteResolved) {
      if (event.generation != state.generation ||
          state.link is! WorkspaceLinkResolving) {
        return RuntimeTransition(state);
      }
      return switch (event.resolution) {
        TransportBlocked(:final blocker) => RuntimeTransition(
          state.copyWith(
            link: WorkspaceLinkBlocked(
              blocker: blocker,
              session: _attachedSession(state.link),
            ),
          ),
          effects: [
            if (event.shouldSuspend)
              _SuspendTransport(
                generation: state.generation,
                reason: blocker.message,
              ),
          ],
        ),
        final TransportReady ready => RuntimeTransition(
          state.copyWith(
            link: WorkspaceLinkEstablishing(
              attempt: event.attempt,
              reconnect: event.reconnect,
              session: _attachedSession(state.link),
              force: event.force,
              promotion: event.promotion,
            ),
          ),
          effects: [
            _EstablishTransport(
              generation: event.generation,
              ready: ready,
              force: event.force,
              reconnect: event.reconnect,
              promotion: event.promotion,
            ),
          ],
        ),
      };
    }

    if (event is _TransportEstablished) {
      if (event.generation != state.generation ||
          state.link is! WorkspaceLinkDesiredConnected) {
        return RuntimeTransition(state);
      }
      if (event.promoteRendezvous) {
        return _beginResolve(
          state,
          force: true,
          reconnect: true,
          attempt: _attempt(state.link),
          promotion: true,
        );
      }
      return _transitionForConnectionStatus(
        state,
        event.status,
        event.transportAvailable,
        event.serverKind,
        recoverFailures: true,
      );
    }

    if (event is _RetryDue) {
      if (state.link case WorkspaceLinkRecovering(:final attempt)
          when state.generation == event.generation &&
              attempt == event.attempt &&
              state.activity is! WorkspaceActivityPaused) {
        return _beginResolve(
          state,
          force: true,
          reconnect: true,
          attempt: attempt,
        );
      }
      return RuntimeTransition(state);
    }

    if (event is _DisconnectCompleted) {
      if (state.link is WorkspaceLinkDisconnecting &&
          state.generation == event.generation) {
        return RuntimeTransition(
          state.copyWith(link: const WorkspaceLinkDisconnected()),
        );
      }
      return RuntimeTransition(state);
    }

    if (event is _SuspendCompleted) return RuntimeTransition(state);

    if (event is _WorkspaceEffectFailed) {
      if (event.effect.generation != state.generation) {
        return RuntimeTransition(state);
      }
      if (event.effect is _DisconnectTransport) {
        return RuntimeTransition(
          state.copyWith(link: const WorkspaceLinkDisconnected()),
        );
      }
      if (event.effect is _SuspendTransport || event.effect is _SetForeground) {
        return RuntimeTransition(state);
      }
      if (!state.wantsConnection || state.activity is WorkspaceActivityPaused) {
        return RuntimeTransition(state);
      }
      return _recover(state, event.error);
    }

    return RuntimeTransition(state);
  }

  RuntimeTransition<WorkspaceRuntimeState, _WorkspaceEffect>
  _reduceConnectionChanged(
    WorkspaceRuntimeState state,
    _ConnectionChanged event,
  ) {
    if (state.link is WorkspaceLinkDisconnecting) {
      return RuntimeTransition(state);
    }
    final recoverFailures = state.activity is! WorkspaceActivityPaused;
    return _transitionForConnectionStatus(
      state,
      event.status,
      event.transportAvailable,
      event.serverKind,
      recoverFailures: recoverFailures,
    );
  }

  RuntimeTransition<WorkspaceRuntimeState, _WorkspaceEffect>
  _transitionForConnectionStatus(
    WorkspaceRuntimeState state,
    WorkspaceConnectionStatus status,
    bool transportAvailable,
    ServerKind serverKind, {
    required bool recoverFailures,
  }) {
    switch (status) {
      case ConnConnecting():
        if (state.link is WorkspaceLinkSynchronizing) {
          return RuntimeTransition(state);
        }
        if (!state.wantsConnection) return RuntimeTransition(state);
        return RuntimeTransition(
          state.copyWith(
            link: WorkspaceLinkEstablishing(
              attempt: _attempt(state.link),
              reconnect: true,
              session: _attachedSession(state.link),
              force: true,
              promotion: false,
            ),
          ),
        );
      case ConnConnected():
        if (!transportAvailable || !state.wantsConnection) {
          return RuntimeTransition(state);
        }
        return RuntimeTransition(
          state.copyWith(link: const WorkspaceLinkReady()),
          invalidateEffects: state.link is WorkspaceLinkRecovering,
        );
      case ConnAttached(:final session):
        if (!transportAvailable || !state.wantsConnection) {
          return RuntimeTransition(state);
        }
        return RuntimeTransition(
          state.copyWith(link: WorkspaceLinkAttached(session)),
          invalidateEffects: state.link is WorkspaceLinkRecovering,
        );
      case ConnSuspended(:final message, :final session):
        if (!state.wantsConnection) return RuntimeTransition(state);
        if (state.link is WorkspaceLinkBlocked) {
          return RuntimeTransition(state);
        }
        return RuntimeTransition(
          state.copyWith(
            link: WorkspaceLinkBlocked(
              blocker: ConnectionBlocker.transport(message, kind: serverKind),
              session: session ?? _attachedSession(state.link),
            ),
          ),
        );
      case ConnFailed(:final message):
        if (!state.wantsConnection) return RuntimeTransition(state);
        // A recovery effect first marks the resource adapter as failed. That
        // callback describes the same loss and must not supersede the pending
        // retry with a second recovery sequence.
        if (state.link is WorkspaceLinkRecovering) {
          return RuntimeTransition(state);
        }
        if (!recoverFailures) {
          return RuntimeTransition(
            state.copyWith(
              link: WorkspaceLinkRecovering(
                attempt: _attempt(state.link) + 1,
                error: message,
                delay: Duration.zero,
                session: _attachedSession(state.link),
              ),
            ),
          );
        }
        return _recover(state, message);
      case ConnDisconnected():
        if (!state.wantsConnection) {
          if (state.link is WorkspaceLinkDisconnected) {
            return RuntimeTransition(state);
          }
          return RuntimeTransition(
            state.copyWith(link: const WorkspaceLinkDisconnected()),
          );
        }
        if (!recoverFailures) {
          return RuntimeTransition(
            state.copyWith(
              link: WorkspaceLinkRecovering(
                attempt: _attempt(state.link) + 1,
                error: 'connection lost',
                delay: Duration.zero,
                session: _attachedSession(state.link),
              ),
            ),
          );
        }
        return _recover(state, 'connection lost');
    }
  }

  RuntimeTransition<WorkspaceRuntimeState, _WorkspaceEffect> _beginResolve(
    WorkspaceRuntimeState state, {
    required bool force,
    required bool reconnect,
    required int attempt,
    bool promotion = false,
    List<_WorkspaceEffect> extraEffects = const [],
  }) {
    final generation = state.generation + 1;
    return RuntimeTransition(
      state.copyWith(
        generation: generation,
        link: WorkspaceLinkResolving(
          attempt: attempt,
          reconnect: reconnect,
          session: _attachedSession(state.link),
          force: force,
          promotion: promotion,
        ),
      ),
      invalidateEffects: true,
      effects: [
        _ResolveRoute(
          generation: generation,
          force: force,
          reconnect: reconnect,
          attempt: attempt,
          promotion: promotion,
        ),
        ...extraEffects,
      ],
    );
  }

  RuntimeTransition<WorkspaceRuntimeState, _WorkspaceEffect> _recover(
    WorkspaceRuntimeState state,
    Object error, {
    bool immediate = false,
    String? markLostMessage,
  }) {
    final attempt = _attempt(state.link) + 1;
    final delay = immediate ? Duration.zero : _reconnectDelay(attempt - 1);
    return RuntimeTransition(
      state.copyWith(
        link: WorkspaceLinkRecovering(
          attempt: attempt,
          error: error,
          delay: delay,
          session: _attachedSession(state.link),
        ),
      ),
      invalidateEffects: true,
      effects: [
        _RecoverTransport(
          generation: state.generation,
          attempt: attempt,
          delay: delay,
          markLostMessage: markLostMessage,
        ),
      ],
    );
  }

  Future<_WorkspaceEvent?> _execute(
    _WorkspaceEffect effect,
    RuntimeEffectContext context,
  ) async {
    switch (effect) {
      case _ResolveRoute(
        :final generation,
        :final force,
        :final reconnect,
        :final attempt,
        :final promotion,
      ):
        final server = serverProvider();
        if (server == null) throw StateError('Unknown server: $serverId');
        if (force || reconnect) await resolver.stopForwarder(server.id);
        final resolution = await resolver.resolve(server);
        if (!context.isCurrent) return null;
        return _RouteResolved(
          generation: generation,
          resolution: resolution,
          force: force,
          reconnect: reconnect,
          attempt: attempt,
          promotion: promotion,
          shouldSuspend: connection.isLive || connection.hasTerminalSnapshot,
        );
      case _EstablishTransport(
        :final generation,
        :final ready,
        :final force,
        :final reconnect,
        :final promotion,
      ):
        await connection.connect(
          ready.target,
          force: force || reconnect,
          proxy: ready.proxy,
          certPin: ready.certPin,
        );
        if (!context.isCurrent) return null;
        final server = serverProvider();
        final promote =
            !promotion &&
            !kIsWeb &&
            server != null &&
            server.kind == ServerKind.rendezvous &&
            resolver.learnRzvDirect(server, connection.lastPing);
        return _TransportEstablished(
          generation: generation,
          status: connection.state,
          transportAvailable: connection.connection.transportAvailable,
          promoteRendezvous: promote,
          serverKind: server?.kind ?? ServerKind.direct,
        );
      case _RecoverTransport(
        :final generation,
        :final attempt,
        :final delay,
        :final markLostMessage,
      ):
        if (markLostMessage != null) {
          await connection.markConnectionLost(markLostMessage);
        }
        if (!context.isCurrent) return null;
        if (!await context.delay(delay)) return null;
        if (!context.isCurrent) return null;
        return _RetryDue(generation: generation, attempt: attempt);
      case _DisconnectTransport(:final generation):
        await connection.disconnect();
        await resolver.stopForwarder(serverId);
        resolver.forgetRzvDirect(serverId);
        return _DisconnectCompleted(generation: generation);
      case _SuspendTransport(:final generation, :final reason):
        await connection.suspendTransport(reason);
        return _SuspendCompleted(generation: generation);
      case _SetForeground(:final foreground):
        connection.setForeground(foreground);
        return null;
    }
  }

  void _onTransition(
    RuntimeTransitionRecord<WorkspaceRuntimeState, _WorkspaceEvent> transition,
  ) {
    switch (transition.event) {
      case _WorkspaceEffectFailed(
        :final effect,
        :final error,
        :final stackTrace,
      ):
        Log.w(
          'workspace runtime effect failed server=$serverId '
          'session=${connection.session} effect=${effect.runtimeType}',
          name: 'motif.runtime',
          error: error,
          stackTrace: stackTrace,
        );
      case _TransportFailure(:final error, :final stackTrace):
        Log.w(
          'workspace transport failure entered recovery server=$serverId',
          name: 'motif.runtime',
          error: error,
          stackTrace: stackTrace,
        );
      default:
        break;
    }
    _project(transition.current);
    Log.i(
      'workspace transition server=$serverId session=${connection.session} '
      'event=${transition.event.runtimeType} '
      'from=${transition.previous.link.runtimeType} '
      'to=${transition.current.link.runtimeType} '
      'activity=${transition.current.activity.runtimeType} '
      'generation=${transition.current.generation} scope=${transition.scope}',
      name: 'motif.runtime',
    );
    _settleWaiters();
  }

  void _project(WorkspaceRuntimeState state) {
    final link = state.link;
    observationTransaction(() {
      final viewModel = connection.connection;
      viewModel.runtime = state;
      viewModel.desiredConnected = state.wantsConnection;
      switch (link) {
        case WorkspaceLinkDisconnected() || WorkspaceLinkDisconnecting():
          viewModel
            ..phase = WorkspaceConnectionPhase.disconnected
            ..transportAvailable = false
            ..reconnectAttempt = 0
            ..message = null
            ..blocker = null
            ..attachedSession = null;
        case WorkspaceLinkSynchronizing(
          :final attempt,
          :final reconnect,
          :final session,
        ):
          viewModel
            ..phase = reconnect
                ? WorkspaceConnectionPhase.reconnecting
                : WorkspaceConnectionPhase.connecting
            ..reconnectAttempt = attempt
            ..message = null
            ..blocker = null
            ..attachedSession = session;
        case WorkspaceLinkReady():
          viewModel
            ..phase = WorkspaceConnectionPhase.ready
            ..reconnectAttempt = 0
            ..message = null
            ..blocker = null
            ..attachedSession = null;
        case WorkspaceLinkAttached(:final session):
          viewModel
            ..phase = WorkspaceConnectionPhase.attached
            ..reconnectAttempt = 0
            ..message = null
            ..blocker = null
            ..attachedSession = session;
        case WorkspaceLinkRecovering(
          :final attempt,
          :final error,
          :final session,
        ):
          viewModel
            ..phase = WorkspaceConnectionPhase.failed
            ..transportAvailable = false
            ..reconnectAttempt = attempt
            ..message = '$error'
            ..blocker = null
            ..attachedSession = session;
        case WorkspaceLinkBlocked(:final blocker, :final session):
          viewModel
            ..phase = WorkspaceConnectionPhase.suspended
            ..transportAvailable = false
            ..message = blocker.message
            ..blocker = blocker
            ..attachedSession = session;
      }
    });
  }

  void _settleWaiters() {
    final state = runtimeState;
    final operationSettled =
        state.activity is WorkspaceActivityPaused ||
        state.link is WorkspaceLinkOnline ||
        state.link is WorkspaceLinkBlocked ||
        state.link is WorkspaceLinkRecovering ||
        state.link is WorkspaceLinkDisconnected;
    if (operationSettled) {
      for (final waiter in _operationWaiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _operationWaiters.clear();
    }
    if (state.link is WorkspaceLinkDisconnected) {
      for (final waiter in _disconnectWaiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _disconnectWaiters.clear();
    }
  }

  int _attempt(WorkspaceLinkState link) => switch (link) {
    WorkspaceLinkSynchronizing(:final attempt) => attempt,
    WorkspaceLinkRecovering(:final attempt) => attempt,
    _ => 0,
  };

  String? _attachedSession(WorkspaceLinkState link) => switch (link) {
    WorkspaceLinkAttached(:final session) => session,
    WorkspaceLinkSynchronizing(:final session) => session,
    WorkspaceLinkRecovering(:final session) => session,
    WorkspaceLinkBlocked(:final session) => session,
    _ => null,
  };

  Duration _reconnectDelay(int attempt) {
    final base =
        _reconnectBaseDelay.inMilliseconds * (1 << attempt.clamp(0, 6));
    final capped = base.clamp(0, _reconnectMaxDelay.inMilliseconds);
    return Duration(milliseconds: capped);
  }
}
