import 'dart:async';

import '../../runtime/runtime_effect.dart';
import '../../runtime/runtime_machine.dart';
import 'terminal_runtime_policy.dart';

sealed class TerminalStreamStatus {
  const TerminalStreamStatus();
}

final class TerminalStreamsIdle extends TerminalStreamStatus {
  const TerminalStreamsIdle();
}

final class TerminalStreamsSynchronizing extends TerminalStreamStatus {
  const TerminalStreamsSynchronizing({
    required this.targetPtyIds,
    required this.activeFirst,
  });

  final Set<String> targetPtyIds;
  final String? activeFirst;
}

final class TerminalStreamsReady extends TerminalStreamStatus {
  const TerminalStreamsReady(this.subscribedPtyIds);

  final Set<String> subscribedPtyIds;
}

final class TerminalStreamsFailed extends TerminalStreamStatus {
  const TerminalStreamsFailed({required this.error, required this.stackTrace});

  final Object error;
  final StackTrace stackTrace;
}

final class TerminalStreamRuntimeState {
  const TerminalStreamRuntimeState({
    required this.generation,
    required this.operationSequence,
    required this.status,
    required this.mountedPtyIds,
    required this.pendingSurfaceOperations,
  });

  const TerminalStreamRuntimeState.initial()
    : generation = 0,
      operationSequence = 0,
      status = const TerminalStreamsIdle(),
      mountedPtyIds = const {},
      pendingSurfaceOperations = const {};

  final int generation;
  final int operationSequence;
  final TerminalStreamStatus status;
  final Set<String> mountedPtyIds;
  final Map<String, int> pendingSurfaceOperations;

  Set<String> get pendingSurfacePtyIds => pendingSurfaceOperations.keys.toSet();

  TerminalStreamRuntimeState copyWith({
    int? generation,
    int? operationSequence,
    TerminalStreamStatus? status,
    Set<String>? mountedPtyIds,
    Map<String, int>? pendingSurfaceOperations,
  }) => TerminalStreamRuntimeState(
    generation: generation ?? this.generation,
    operationSequence: operationSequence ?? this.operationSequence,
    status: status ?? this.status,
    mountedPtyIds: mountedPtyIds ?? this.mountedPtyIds,
    pendingSurfaceOperations:
        pendingSurfaceOperations ?? this.pendingSurfaceOperations,
  );
}

enum TerminalStreamPlatformPolicy { mobile, desktop }

sealed class _TerminalStreamEvent {
  const _TerminalStreamEvent();
}

final class _SessionAttached extends _TerminalStreamEvent {
  const _SessionAttached({
    required this.livePtyIds,
    required this.activePtyId,
    required this.mountedPtyIds,
  });

  final Set<String> livePtyIds;
  final String? activePtyId;
  final Set<String> mountedPtyIds;
}

final class _SubscriptionsChanged extends _TerminalStreamEvent {
  const _SubscriptionsChanged(this.livePtyIds);

  final Set<String> livePtyIds;
}

final class _SurfaceRequested extends _TerminalStreamEvent {
  const _SurfaceRequested({
    required this.operationId,
    required this.ptyId,
    required this.mounted,
  });

  final int operationId;
  final String ptyId;
  final bool mounted;
}

final class _ControlCompleted extends _TerminalStreamEvent {
  const _ControlCompleted({
    required this.generation,
    required this.subscribedPtyIds,
  });

  final int generation;
  final Set<String> subscribedPtyIds;
}

final class _SurfaceCompleted extends _TerminalStreamEvent {
  const _SurfaceCompleted({required this.operationId, required this.ptyId});

  final int operationId;
  final String ptyId;
}

final class _TerminalStreamEffectFailed extends _TerminalStreamEvent {
  const _TerminalStreamEffectFailed({
    required this.effect,
    required this.error,
    required this.stackTrace,
  });

  final _TerminalStreamEffect effect;
  final Object error;
  final StackTrace stackTrace;
}

sealed class _TerminalStreamEffect implements RuntimeEffect {
  const _TerminalStreamEffect();
}

sealed class _TerminalControlEffect extends _TerminalStreamEffect {
  const _TerminalControlEffect({required this.generation});

  final int generation;

  @override
  Object get key => 'terminal-stream-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _RestoreDesktopStreams extends _TerminalControlEffect {
  const _RestoreDesktopStreams({
    required super.generation,
    required this.targetPtyIds,
    required this.activePtyId,
  });

  final Set<String> targetPtyIds;
  final String? activePtyId;
}

final class _SyncDesktopStreams extends _TerminalControlEffect {
  const _SyncDesktopStreams({
    required super.generation,
    required this.targetPtyIds,
  });

  final Set<String> targetPtyIds;
}

final class _RestoreMobileStreams extends _TerminalControlEffect {
  const _RestoreMobileStreams({
    required super.generation,
    required this.targetPtyIds,
  });

  final Set<String> targetPtyIds;
}

final class _UpdateSurfaceStream extends _TerminalStreamEffect {
  const _UpdateSurfaceStream({
    required this.operationId,
    required this.ptyId,
    required this.mounted,
  });

  final int operationId;
  final String ptyId;
  final bool mounted;

  @override
  Object get key => 'terminal-surface:$ptyId';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.serial;
}

/// Per-terminal child node for PTY stream subscription convergence.
final class TerminalStreamRuntimeController {
  TerminalStreamRuntimeController({
    required this.host,
    required this.policy,
    required this.onStateChanged,
    this.backgroundRestoreDelay = const Duration(milliseconds: 32),
  }) {
    _machine =
        RuntimeMachine<
          TerminalStreamRuntimeState,
          _TerminalStreamEvent,
          _TerminalStreamEffect
        >(
          initialState: const TerminalStreamRuntimeState.initial(),
          reducer: _reduce,
          execute: _execute,
          mapEffectError: (effect, error, stackTrace) =>
              _TerminalStreamEffectFailed(
                effect: effect,
                error: error,
                stackTrace: stackTrace,
              ),
          onTransition: (transition) {
            onStateChanged(transition.current);
            _settleSurfaceWaiter(transition.event);
          },
        );
    onStateChanged(_machine.state);
  }

  final TerminalRuntimeHost host;
  final TerminalStreamPlatformPolicy policy;
  final Duration backgroundRestoreDelay;
  final void Function(TerminalStreamRuntimeState state) onStateChanged;

  late final RuntimeMachine<
    TerminalStreamRuntimeState,
    _TerminalStreamEvent,
    _TerminalStreamEffect
  >
  _machine;
  final Map<int, Completer<void>> _surfaceWaiters = {};

  TerminalStreamRuntimeState get state => _machine.state;

  void sessionAttached() => _machine.dispatch(
    _SessionAttached(
      livePtyIds: Set<String>.from(host.liveTabPtyIds),
      activePtyId: host.activePtyId,
      mountedPtyIds: Set<String>.from(host.terminalSurfacePtyIds),
    ),
  );

  void subscriptionsChanged() => _machine.dispatch(
    _SubscriptionsChanged(Set<String>.from(host.liveTabPtyIds)),
  );

  Future<void> surfaceReady(String ptyId) =>
      _requestSurface(ptyId, mounted: true);

  Future<void> surfaceDisposed(String ptyId) =>
      _requestSurface(ptyId, mounted: false);

  Future<void> _requestSurface(String ptyId, {required bool mounted}) {
    final operationId = state.operationSequence + 1;
    final waiter = Completer<void>();
    _surfaceWaiters[operationId] = waiter;
    _machine.dispatch(
      _SurfaceRequested(
        operationId: operationId,
        ptyId: ptyId,
        mounted: mounted,
      ),
    );
    return waiter.future;
  }

  RuntimeTransition<TerminalStreamRuntimeState, _TerminalStreamEffect> _reduce(
    TerminalStreamRuntimeState state,
    _TerminalStreamEvent event,
  ) {
    if (event is _SessionAttached) {
      final generation = state.generation + 1;
      final target = policy == TerminalStreamPlatformPolicy.desktop
          ? event.livePtyIds
          : event.mountedPtyIds.intersection(event.livePtyIds);
      final active =
          event.activePtyId != null && target.contains(event.activePtyId)
          ? event.activePtyId
          : null;
      return RuntimeTransition(
        state.copyWith(
          generation: generation,
          mountedPtyIds: event.mountedPtyIds,
          status: TerminalStreamsSynchronizing(
            targetPtyIds: target,
            activeFirst: active,
          ),
        ),
        invalidateEffects: true,
        effects: [
          if (policy == TerminalStreamPlatformPolicy.desktop)
            _RestoreDesktopStreams(
              generation: generation,
              targetPtyIds: target,
              activePtyId: active,
            )
          else
            _RestoreMobileStreams(generation: generation, targetPtyIds: target),
        ],
      );
    }
    if (event case _SubscriptionsChanged(:final livePtyIds)) {
      if (policy == TerminalStreamPlatformPolicy.mobile) {
        return RuntimeTransition(state);
      }
      final generation = state.generation + 1;
      return RuntimeTransition(
        state.copyWith(
          generation: generation,
          status: TerminalStreamsSynchronizing(
            targetPtyIds: livePtyIds,
            activeFirst: null,
          ),
        ),
        invalidateEffects: true,
        effects: [
          _SyncDesktopStreams(generation: generation, targetPtyIds: livePtyIds),
        ],
      );
    }
    if (event case _SurfaceRequested(
      :final operationId,
      :final ptyId,
      :final mounted,
    )) {
      final mountedPtys = Set<String>.from(state.mountedPtyIds);
      mounted ? mountedPtys.add(ptyId) : mountedPtys.remove(ptyId);
      final pending = Map<String, int>.from(state.pendingSurfaceOperations)
        ..[ptyId] = operationId;
      if (policy == TerminalStreamPlatformPolicy.desktop) {
        return RuntimeTransition(
          state.copyWith(
            operationSequence: operationId,
            mountedPtyIds: mountedPtys,
            pendingSurfaceOperations: pending,
          ),
          effects: [
            _UpdateSurfaceStream(
              operationId: operationId,
              ptyId: ptyId,
              mounted: mounted,
            ),
          ],
        );
      }
      return RuntimeTransition(
        state.copyWith(
          operationSequence: operationId,
          mountedPtyIds: mountedPtys,
          pendingSurfaceOperations: pending,
        ),
        effects: [
          _UpdateSurfaceStream(
            operationId: operationId,
            ptyId: ptyId,
            mounted: mounted,
          ),
        ],
      );
    }
    if (event is _ControlCompleted) {
      if (event.generation != state.generation) return RuntimeTransition(state);
      return RuntimeTransition(
        state.copyWith(status: TerminalStreamsReady(event.subscribedPtyIds)),
      );
    }
    if (event case _SurfaceCompleted(:final operationId, :final ptyId)) {
      if (state.pendingSurfaceOperations[ptyId] != operationId) {
        return RuntimeTransition(state);
      }
      final pending = Map<String, int>.from(state.pendingSurfaceOperations)
        ..remove(ptyId);
      return RuntimeTransition(
        state.copyWith(pendingSurfaceOperations: pending),
      );
    }
    if (event is _TerminalStreamEffectFailed) {
      final effect = event.effect;
      if (effect is _TerminalControlEffect &&
          effect.generation != state.generation) {
        return RuntimeTransition(state);
      }
      final pending = Map<String, int>.from(state.pendingSurfaceOperations);
      if (effect is _UpdateSurfaceStream &&
          pending[effect.ptyId] == effect.operationId) {
        pending.remove(effect.ptyId);
      }
      return RuntimeTransition(
        state.copyWith(
          status: TerminalStreamsFailed(
            error: event.error,
            stackTrace: event.stackTrace,
          ),
          pendingSurfaceOperations: pending,
        ),
      );
    }
    return RuntimeTransition(state);
  }

  Future<_TerminalStreamEvent?> _execute(
    _TerminalStreamEffect effect,
    RuntimeEffectContext context,
  ) async {
    switch (effect) {
      case _RestoreDesktopStreams(
        :final generation,
        :final targetPtyIds,
        :final activePtyId,
      ):
        final restored = <String>{};
        if (activePtyId != null) {
          restored.add(activePtyId);
          await host.syncPtyStreams(restored);
          await host.waitForPtyReplay(activePtyId);
          if (!context.isCurrent) return null;
        }
        for (final ptyId in targetPtyIds) {
          if (restored.contains(ptyId)) continue;
          if (!await context.delay(backgroundRestoreDelay)) return null;
          if (!context.isCurrent) return null;
          restored.add(ptyId);
          await host.syncPtyStreams(restored);
        }
        return _ControlCompleted(
          generation: generation,
          subscribedPtyIds: Set<String>.unmodifiable(restored),
        );
      case _SyncDesktopStreams(:final generation, :final targetPtyIds):
        await host.syncPtyStreams(targetPtyIds);
        if (!context.isCurrent) return null;
        return _ControlCompleted(
          generation: generation,
          subscribedPtyIds: targetPtyIds,
        );
      case _RestoreMobileStreams(:final generation, :final targetPtyIds):
        for (final ptyId in targetPtyIds) {
          await host.ensurePtyStream(ptyId);
          if (!context.isCurrent) return null;
        }
        return _ControlCompleted(
          generation: generation,
          subscribedPtyIds: targetPtyIds,
        );
      case _UpdateSurfaceStream(
        :final operationId,
        :final ptyId,
        :final mounted,
      ):
        if (policy == TerminalStreamPlatformPolicy.mobile) {
          if (mounted) {
            await host.ensurePtyStream(ptyId);
          } else {
            await host.closePtyStream(ptyId);
          }
        }
        return _SurfaceCompleted(operationId: operationId, ptyId: ptyId);
    }
  }

  void _settleSurfaceWaiter(_TerminalStreamEvent event) {
    switch (event) {
      case _SurfaceCompleted(:final operationId):
        _surfaceWaiters.remove(operationId)?.complete();
      case _TerminalStreamEffectFailed(
        effect: _UpdateSurfaceStream(:final operationId),
        :final error,
        :final stackTrace,
      ):
        _surfaceWaiters.remove(operationId)?.completeError(error, stackTrace);
      default:
        break;
    }
  }

  void dispose() {
    _machine.dispose();
    for (final waiter in _surfaceWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _surfaceWaiters.clear();
  }
}
