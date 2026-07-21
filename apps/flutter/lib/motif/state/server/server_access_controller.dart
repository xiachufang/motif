import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../log/log.dart';
import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../connection/connection_state.dart';
import '../platform/tailscale_view_model.dart';
import '../runtime/runtime_effect.dart';
import '../runtime/runtime_machine.dart';
import 'server_runtime_state.dart';
import 'server_transport.dart';
import 'server_view_models.dart';
import 'session_catalog_controller.dart';
import 'session_catalog_view_model.dart';
import 'transport_resolver.dart';

sealed class _ServerEvent {
  const _ServerEvent();
}

final class _ConnectRequested extends _ServerEvent {
  const _ConnectRequested({required this.force});

  final bool force;
}

final class _AdoptLiveTransport extends _ServerEvent {
  const _AdoptLiveTransport();
}

final class _RefreshRequested extends _ServerEvent {
  const _RefreshRequested({required this.transportLive});

  final bool transportLive;
}

final class _DisconnectRequested extends _ServerEvent {
  const _DisconnectRequested();
}

final class _AppPaused extends _ServerEvent {
  const _AppPaused();
}

final class _AppResumed extends _ServerEvent {
  const _AppResumed({required this.transportLive});

  final bool transportLive;
}

final class _TransportAvailabilityChanged extends _ServerEvent {
  const _TransportAvailabilityChanged(this.blocker);

  final ConnectionBlocker? blocker;
}

final class _ExternalTransportFailure extends _ServerEvent {
  const _ExternalTransportFailure(this.error);

  final Object error;
}

final class _RouteResolved extends _ServerEvent {
  const _RouteResolved({
    required this.generation,
    required this.resolution,
    required this.force,
    required this.reconnect,
    required this.attempt,
    required this.promotion,
  });

  final int generation;
  final TransportResolution resolution;
  final bool force;
  final bool reconnect;
  final int attempt;
  final bool promotion;
}

final class _TransportEstablished extends _ServerEvent {
  const _TransportEstablished({
    required this.generation,
    required this.attempt,
    required this.reconnect,
    required this.promoteRendezvous,
  });

  final int generation;
  final int attempt;
  final bool reconnect;
  final bool promoteRendezvous;
}

final class _CatalogLoaded extends _ServerEvent {
  const _CatalogLoaded({
    required this.generation,
    required this.sessions,
    required this.updatedAt,
  });

  final int generation;
  final List<SessionInfo> sessions;
  final DateTime updatedAt;
}

final class _RetryDue extends _ServerEvent {
  const _RetryDue({required this.generation, required this.attempt});

  final int generation;
  final int attempt;
}

final class _DisconnectCompleted extends _ServerEvent {
  const _DisconnectCompleted({required this.generation});

  final int generation;
}

final class _TransportClosed extends _ServerEvent {
  const _TransportClosed({required this.generation});

  final int generation;
}

final class _EffectFailed extends _ServerEvent {
  const _EffectFailed({
    required this.effect,
    required this.error,
    required this.stackTrace,
  });

  final _ServerEffect effect;
  final Object error;
  final StackTrace stackTrace;
}

sealed class _ServerEffect implements RuntimeEffect {
  const _ServerEffect({required this.generation});

  final int generation;
}

final class _ResolveRoute extends _ServerEffect {
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
  Object get key => 'server-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _EstablishTransport extends _ServerEffect {
  const _EstablishTransport({
    required super.generation,
    required this.ready,
    required this.force,
    required this.reconnect,
    required this.attempt,
    required this.promotion,
  });

  final TransportReady ready;
  final bool force;
  final bool reconnect;
  final int attempt;
  final bool promotion;

  @override
  Object get key => 'server-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _LoadCatalog extends _ServerEffect {
  const _LoadCatalog({required super.generation});

  @override
  Object get key => 'server-catalog';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.coalescing;
}

final class _RecoverTransport extends _ServerEffect {
  const _RecoverTransport({
    required super.generation,
    required this.attempt,
    required this.delay,
  });

  final int attempt;
  final Duration delay;

  @override
  Object get key => 'server-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _DisconnectTransport extends _ServerEffect {
  const _DisconnectTransport({required super.generation});

  @override
  Object get key => 'server-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _CloseTransport extends _ServerEffect {
  const _CloseTransport({required super.generation});

  @override
  Object get key => 'server-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

/// Hierarchical runtime state machine for one server-scoped control channel.
///
/// The existing ViewModels are projections only. Connection, route promotion,
/// initial catalog loading and recovery all flow through [_machine].
final class ServerAccessController {
  static const Duration _reconnectBaseDelay = Duration(milliseconds: 500);
  static const Duration _reconnectMaxDelay = Duration(seconds: 30);

  ServerAccessController({
    required this.serverId,
    required this.serverProvider,
    required this.resolver,
    required this.transport,
    required this.sessions,
    required this.viewModel,
    this.onChanged,
  }) {
    _machine = RuntimeMachine<ServerRuntimeState, _ServerEvent, _ServerEffect>(
      initialState: const ServerRuntimeDisconnected(),
      reducer: _reduce,
      execute: _execute,
      mapEffectError: (effect, error, stackTrace) =>
          _EffectFailed(effect: effect, error: error, stackTrace: stackTrace),
      onTransition: _onTransition,
    );
    sessions.refreshDelegate = refreshSessions;
    _project(_machine.state, notify: false);
    if (transport.isLive) {
      scheduleMicrotask(() {
        if (!_machine.isDisposed) {
          _machine.dispatch(const _AdoptLiveTransport());
        }
      });
    }
  }

  final String serverId;
  final MotifServer? Function() serverProvider;
  final TransportResolver resolver;
  final ServerTransport transport;
  final SessionCatalogController sessions;
  final ServerAccessViewModel viewModel;
  final VoidCallback? onChanged;

  late final RuntimeMachine<ServerRuntimeState, _ServerEvent, _ServerEffect>
  _machine;
  final List<Completer<void>> _operationWaiters = [];
  final List<Completer<void>> _disconnectWaiters = [];

  ServerRuntimeState get runtimeState => _machine.state;
  bool get isLive => transport.isLive;
  bool get isReady => runtimeState.isOnline;
  bool get wantsConnection => runtimeState.wantsConnection;

  ServerConnectionState get state => _connectionState(runtimeState);

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

  Future<void> refreshSessions() {
    if (!isLive || !runtimeState.wantsConnection) return Future<void>.value();
    final waiter = Completer<void>();
    _operationWaiters.add(waiter);
    _machine.dispatch(_RefreshRequested(transportLive: isLive));
    _settleWaiters();
    return waiter.future;
  }

  /// Compatibility entry point for callers that have already classified an
  /// RPC failure as a dead transport.
  void handleRefreshFailed(Object error, [StackTrace? stackTrace]) {
    if (!runtimeState.wantsConnection) return;
    Log.w(
      'session refresh failed; reconciling server=$serverId',
      name: 'motif.reconnect',
      error: error,
      stackTrace: stackTrace,
    );
    _machine.dispatch(_ExternalTransportFailure(error));
  }

  void handleTailscaleState(TailscaleState _) {
    final server = serverProvider();
    if (server == null || server.kind != ServerKind.tailscale) return;
    _machine.dispatch(
      _TransportAvailabilityChanged(resolver.currentBlocker(server)),
    );
  }

  void handleAppPaused() => _machine.dispatch(const _AppPaused());

  void handleAppResumed() =>
      _machine.dispatch(_AppResumed(transportLive: isLive));

  void dispose() {
    sessions.refreshDelegate = null;
    _machine.dispose();
    for (final waiter in [..._operationWaiters, ..._disconnectWaiters]) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _operationWaiters.clear();
    _disconnectWaiters.clear();
    unawaited(resolver.stopForwarder(serverId));
    resolver.forgetRzvDirect(serverId);
  }

  RuntimeTransition<ServerRuntimeState, _ServerEffect> _reduce(
    ServerRuntimeState state,
    _ServerEvent event,
  ) {
    if (event is _AppPaused) {
      if (state is ServerRuntimePaused) return RuntimeTransition(state);
      return RuntimeTransition(
        ServerRuntimePaused(state),
        invalidateEffects: true,
      );
    }

    if (event is _AppResumed) {
      if (state case ServerRuntimePaused(:final previous)) {
        if (!previous.wantsConnection) {
          return RuntimeTransition(
            ServerRuntimeDisconnected(generation: previous.generation),
          );
        }
        if (event.transportLive &&
            previous.visibleState is ServerRuntimeOnline) {
          return RuntimeTransition(
            ServerRuntimeRefreshing(
              generation: previous.generation,
              previousUpdatedAt: _updatedAt(previous),
            ),
            effects: [_LoadCatalog(generation: previous.generation)],
          );
        }
        return _beginResolve(
          previous,
          force: true,
          reconnect: true,
          attempt: _attempt(previous),
        );
      }
      return RuntimeTransition(state);
    }

    if (event is _DisconnectRequested) {
      final generation = state.generation + 1;
      return RuntimeTransition(
        ServerRuntimeDisconnecting(generation: generation),
        invalidateEffects: true,
        effects: [_DisconnectTransport(generation: generation)],
      );
    }

    if (event is _AdoptLiveTransport) {
      if (state.wantsConnection) return RuntimeTransition(state);
      final generation = state.generation + 1;
      return RuntimeTransition(
        ServerRuntimeLoadingCatalog(
          generation: generation,
          attempt: 0,
          reconnect: false,
        ),
        effects: [_LoadCatalog(generation: generation)],
      );
    }

    if (event is _ConnectRequested) {
      if (state case ServerRuntimePaused(:final previous)) {
        final pending = ServerRuntimeResolving(
          generation: previous.generation + 1,
          attempt: 0,
          reconnect: false,
          force: event.force,
        );
        return RuntimeTransition(ServerRuntimePaused(pending));
      }
      if (!event.force && state is ServerRuntimeSynchronizing) {
        return RuntimeTransition(state);
      }
      if (!event.force && state is ServerRuntimeOnline) {
        return RuntimeTransition(
          ServerRuntimeRefreshing(
            generation: state.generation,
            previousUpdatedAt: _updatedAt(state),
          ),
          effects: [_LoadCatalog(generation: state.generation)],
        );
      }
      return _beginResolve(
        state,
        force: event.force,
        // Public connect/retry requests are user-visible connection attempts.
        // Automatic retry events set reconnect=true at their own call sites.
        reconnect: false,
        attempt: event.force ? 0 : _attempt(state),
      );
    }

    if (event is _RefreshRequested) {
      if (state is ServerRuntimePaused || !state.wantsConnection) {
        return RuntimeTransition(state);
      }
      if (!event.transportLive) {
        return _beginResolve(
          state,
          force: true,
          reconnect: true,
          attempt: _attempt(state),
        );
      }
      if (state is ServerRuntimeOnline) {
        return RuntimeTransition(
          ServerRuntimeRefreshing(
            generation: state.generation,
            previousUpdatedAt: _updatedAt(state),
          ),
          effects: [_LoadCatalog(generation: state.generation)],
        );
      }
      return RuntimeTransition(state);
    }

    if (event case _TransportAvailabilityChanged(:final blocker)) {
      if (state is ServerRuntimePaused || !state.wantsConnection) {
        return RuntimeTransition(state);
      }
      if (blocker != null) {
        return RuntimeTransition(
          ServerRuntimeBlocked(generation: state.generation, blocker: blocker),
          invalidateEffects: true,
          effects: [_CloseTransport(generation: state.generation)],
        );
      }
      if (state is ServerRuntimeBlocked) {
        return _beginResolve(state, force: true, reconnect: true, attempt: 0);
      }
      return RuntimeTransition(state);
    }

    if (event case _ExternalTransportFailure(:final error)) {
      if (!state.wantsConnection || state is ServerRuntimePaused) {
        return RuntimeTransition(state);
      }
      return _recover(state, error);
    }

    if (event is _RouteResolved) {
      if (event.generation != state.generation ||
          state is! ServerRuntimeSynchronizing) {
        return RuntimeTransition(state);
      }
      return switch (event.resolution) {
        TransportBlocked(:final blocker) => RuntimeTransition(
          ServerRuntimeBlocked(generation: event.generation, blocker: blocker),
        ),
        final TransportReady ready => RuntimeTransition(
          ServerRuntimeEstablishing(
            generation: event.generation,
            attempt: event.attempt,
            reconnect: event.reconnect,
            target: ready.target,
            force: event.force,
            promotion: event.promotion,
          ),
          effects: [
            _EstablishTransport(
              generation: event.generation,
              ready: ready,
              force: event.force,
              reconnect: event.reconnect,
              attempt: event.attempt,
              promotion: event.promotion,
            ),
          ],
        ),
      };
    }

    if (event is _TransportEstablished) {
      if (event.generation != state.generation ||
          state is! ServerRuntimeSynchronizing) {
        return RuntimeTransition(state);
      }
      if (event.promoteRendezvous) {
        return RuntimeTransition(
          ServerRuntimePromotingRoute(
            generation: event.generation,
            attempt: event.attempt,
            reconnect: event.reconnect,
          ),
          effects: [
            _ResolveRoute(
              generation: event.generation,
              force: true,
              reconnect: true,
              attempt: event.attempt,
              promotion: true,
            ),
          ],
        );
      }
      return RuntimeTransition(
        ServerRuntimeLoadingCatalog(
          generation: event.generation,
          attempt: event.attempt,
          reconnect: event.reconnect,
        ),
        effects: [_LoadCatalog(generation: event.generation)],
      );
    }

    if (event is _CatalogLoaded) {
      if (event.generation != state.generation ||
          (state is! ServerRuntimeLoadingCatalog &&
              state is! ServerRuntimeRefreshing)) {
        return RuntimeTransition(state);
      }
      return RuntimeTransition(
        ServerRuntimeReady(
          generation: event.generation,
          catalogUpdatedAt: event.updatedAt,
        ),
      );
    }

    if (event is _RetryDue) {
      if (state case ServerRuntimeRecovering(
        :final generation,
        :final attempt,
      ) when generation == event.generation && attempt == event.attempt) {
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
      if (state is ServerRuntimeDisconnecting &&
          event.generation == state.generation) {
        return RuntimeTransition(
          ServerRuntimeDisconnected(generation: event.generation),
        );
      }
      return RuntimeTransition(state);
    }

    if (event is _TransportClosed) return RuntimeTransition(state);

    if (event is _EffectFailed) {
      final effect = event.effect;
      if (effect.generation != state.generation) {
        return RuntimeTransition(state);
      }
      Log.w(
        'server runtime effect failed server=$serverId '
        'effect=${effect.runtimeType} generation=${effect.generation}',
        name: 'motif.runtime',
        error: event.error,
        stackTrace: event.stackTrace,
      );
      if (effect is _DisconnectTransport) {
        return RuntimeTransition(
          ServerRuntimeDisconnected(generation: effect.generation),
        );
      }
      if (effect is _CloseTransport) return RuntimeTransition(state);
      if (effect is _LoadCatalog && event.error is! ServerTransportException) {
        return RuntimeTransition(
          ServerRuntimeDegraded(
            generation: state.generation,
            error: event.error,
            previousUpdatedAt: sessions.viewModel.lastUpdatedAt,
          ),
        );
      }
      return _recover(state, event.error);
    }

    return RuntimeTransition(state);
  }

  RuntimeTransition<ServerRuntimeState, _ServerEffect> _beginResolve(
    ServerRuntimeState state, {
    required bool force,
    required bool reconnect,
    required int attempt,
  }) {
    final generation = state.generation + 1;
    return RuntimeTransition(
      ServerRuntimeResolving(
        generation: generation,
        attempt: attempt,
        reconnect: reconnect,
        force: force,
      ),
      invalidateEffects: true,
      effects: [
        _ResolveRoute(
          generation: generation,
          force: force,
          reconnect: reconnect,
          attempt: attempt,
          promotion: false,
        ),
      ],
    );
  }

  RuntimeTransition<ServerRuntimeState, _ServerEffect> _recover(
    ServerRuntimeState state,
    Object error,
  ) {
    final attempt = _attempt(state) + 1;
    final delay = _reconnectDelay(attempt - 1);
    final server = serverProvider();
    final visibleError = server == null
        ? '$error'
        : _friendlyError(server, error);
    return RuntimeTransition(
      ServerRuntimeRecovering(
        generation: state.generation,
        attempt: attempt,
        error: visibleError,
        delay: delay,
      ),
      invalidateEffects: true,
      effects: [
        _RecoverTransport(
          generation: state.generation,
          attempt: attempt,
          delay: delay,
        ),
      ],
    );
  }

  Future<_ServerEvent?> _execute(
    _ServerEffect effect,
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
        );
      case _EstablishTransport(
        :final generation,
        :final ready,
        :final force,
        :final reconnect,
        :final attempt,
        :final promotion,
      ):
        final ping = await transport.connect(
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
            resolver.learnRzvDirect(server, ping);
        return _TransportEstablished(
          generation: generation,
          attempt: attempt,
          reconnect: reconnect,
          promoteRendezvous: promote,
        );
      case _LoadCatalog(:final generation):
        final loaded = await sessions.fetch();
        if (!context.isCurrent) return null;
        return _CatalogLoaded(
          generation: generation,
          sessions: loaded,
          updatedAt: DateTime.now(),
        );
      case _RecoverTransport(:final generation, :final attempt, :final delay):
        await transport.close();
        if (!context.isCurrent) return null;
        if (!await context.delay(delay)) return null;
        if (!context.isCurrent) return null;
        return _RetryDue(generation: generation, attempt: attempt);
      case _DisconnectTransport(:final generation):
        await transport.close();
        await resolver.stopForwarder(serverId);
        resolver.forgetRzvDirect(serverId);
        return _DisconnectCompleted(generation: generation);
      case _CloseTransport(:final generation):
        await transport.close();
        return _TransportClosed(generation: generation);
    }
  }

  void _onTransition(
    RuntimeTransitionRecord<ServerRuntimeState, _ServerEvent> transition,
  ) {
    if (transition.event case _CatalogLoaded(
      :final sessions,
      :final updatedAt,
    )) {
      this.sessions.viewModel.sessions.replaceRange(
        0,
        this.sessions.viewModel.sessions.length,
        sessions,
      );
      this.sessions.viewModel.lastUpdatedAt = updatedAt;
    }
    _project(transition.current);
    Log.i(
      'server transition server=$serverId '
      'event=${transition.event.runtimeType} '
      'from=${transition.previous.runtimeType} '
      'to=${transition.current.runtimeType} '
      'generation=${transition.current.generation} scope=${transition.scope}',
      name: 'motif.runtime',
    );
    _settleWaiters();
  }

  void _project(ServerRuntimeState state, {bool notify = true}) {
    final visible = state.visibleState;
    observationTransaction(() {
      viewModel.runtime = state;
      switch (visible) {
        case ServerRuntimeDisconnected() || ServerRuntimeDisconnecting():
          viewModel
            ..phase = ServerAccessPhase.idle
            ..blocker = null
            ..error = null;
        case ServerRuntimeSynchronizing():
          viewModel
            ..phase = ServerAccessPhase.resolving
            ..blocker = null
            ..error = null;
        case ServerRuntimeOnline():
          viewModel
            ..phase = ServerAccessPhase.ready
            ..blocker = null
            ..error = visible is ServerRuntimeDegraded
                ? '${visible.error}'
                : null;
        case ServerRuntimeRecovering(:final error):
          viewModel
            ..phase = ServerAccessPhase.failed
            ..blocker = null
            ..error = '$error';
        case ServerRuntimeBlocked(:final blocker):
          viewModel
            ..phase = ServerAccessPhase.blocked
            ..blocker = blocker
            ..error = null;
        case ServerRuntimePaused():
          throw StateError('visibleState must unwrap paused state');
      }

      switch (visible) {
        case ServerRuntimeLoadingCatalog() || ServerRuntimeRefreshing():
          sessions.viewModel
            ..phase = SessionCatalogPhase.loading
            ..error = null;
        case ServerRuntimeReady():
          sessions.viewModel
            ..phase = SessionCatalogPhase.ready
            ..error = null;
        case ServerRuntimeDegraded(:final error):
          sessions.viewModel
            ..phase = SessionCatalogPhase.failed
            ..error = '$error';
        case ServerRuntimeRecovering(:final error):
          sessions.viewModel
            ..phase = SessionCatalogPhase.failed
            ..error = '$error';
        default:
          break;
      }
    });
    if (notify) onChanged?.call();
  }

  void _settleWaiters() {
    final visible = runtimeState.visibleState;
    final operationSettled =
        visible is ServerRuntimeOnline ||
        visible is ServerRuntimeBlocked ||
        visible is ServerRuntimeRecovering ||
        visible is ServerRuntimeDisconnected;
    if (operationSettled) {
      for (final waiter in _operationWaiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _operationWaiters.clear();
    }
    if (visible is ServerRuntimeDisconnected) {
      for (final waiter in _disconnectWaiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _disconnectWaiters.clear();
    }
  }

  ServerConnectionState _connectionState(ServerRuntimeState state) {
    return switch (state.visibleState) {
      ServerRuntimeDisconnected() ||
      ServerRuntimeDisconnecting() => const ServerIdle(),
      ServerRuntimeSynchronizing(:final reconnect, :final attempt) =>
        reconnect
            ? ServerReconnecting(attempt: attempt)
            : const ServerConnecting(),
      ServerRuntimeOnline() => const ServerConnected(),
      ServerRuntimeRecovering(:final error) => ServerFailed('$error'),
      ServerRuntimeBlocked(:final blocker) => ServerBlocked(blocker),
      ServerRuntimePaused() => throw StateError(
        'visibleState must unwrap paused state',
      ),
    };
  }

  int _attempt(ServerRuntimeState state) => switch (state.visibleState) {
    ServerRuntimeSynchronizing(:final attempt) => attempt,
    ServerRuntimeRecovering(:final attempt) => attempt,
    _ => 0,
  };

  DateTime? _updatedAt(ServerRuntimeState state) =>
      switch (state.visibleState) {
        ServerRuntimeReady(:final catalogUpdatedAt) => catalogUpdatedAt,
        ServerRuntimeRefreshing(:final previousUpdatedAt) => previousUpdatedAt,
        ServerRuntimeDegraded(:final previousUpdatedAt) => previousUpdatedAt,
        _ => sessions.viewModel.lastUpdatedAt,
      };

  Duration _reconnectDelay(int attempt) {
    final base =
        _reconnectBaseDelay.inMilliseconds * (1 << attempt.clamp(0, 6));
    final capped = base.clamp(0, _reconnectMaxDelay.inMilliseconds);
    return Duration(milliseconds: capped);
  }

  String _friendlyError(MotifServer server, Object error) {
    final message = '$error';
    return switch (server.kind) {
      ServerKind.tailscale =>
        "Can't reach ${server.endpoint} over Tailscale. $message",
      ServerKind.ssh =>
        "Can't reach ${server.endpoint} through the SSH tunnel. $message",
      ServerKind.wsl => "Can't reach ${server.endpoint} through WSL. $message",
      _ => "Can't reach ${server.endpoint}. $message",
    };
  }
}
