import 'dart:async';

import '../../runtime/runtime_effect.dart';
import '../../runtime/runtime_machine.dart';

sealed class WorkspaceAttachmentRuntimeState {
  const WorkspaceAttachmentRuntimeState({required this.generation});

  final int generation;
}

final class WorkspaceAttachmentDetached
    extends WorkspaceAttachmentRuntimeState {
  const WorkspaceAttachmentDetached({super.generation = 0});
}

final class WorkspaceAttachmentAttaching
    extends WorkspaceAttachmentRuntimeState {
  const WorkspaceAttachmentAttaching({required super.generation});
}

final class WorkspaceAttachmentAttached
    extends WorkspaceAttachmentRuntimeState {
  const WorkspaceAttachmentAttached({
    required super.generation,
    required this.rpcSessionId,
  });

  final String? rpcSessionId;
}

final class WorkspaceAttachmentRecovering
    extends WorkspaceAttachmentRuntimeState {
  const WorkspaceAttachmentRecovering({
    required super.generation,
    required this.expiredSessionId,
  });

  final String expiredSessionId;
}

final class WorkspaceAttachmentFailed extends WorkspaceAttachmentRuntimeState {
  const WorkspaceAttachmentFailed({
    required super.generation,
    required this.error,
    required this.stackTrace,
  });

  final Object error;
  final StackTrace stackTrace;
}

sealed class _AttachmentEvent {
  const _AttachmentEvent();
}

final class _AttachRequested extends _AttachmentEvent {
  const _AttachRequested();
}

final class _RecoveryRequested extends _AttachmentEvent {
  const _RecoveryRequested(this.expiredSessionId);

  final String expiredSessionId;
}

final class _AttachmentReset extends _AttachmentEvent {
  const _AttachmentReset();
}

final class _AttachmentCompleted extends _AttachmentEvent {
  const _AttachmentCompleted({
    required this.generation,
    required this.rpcSessionId,
  });

  final int generation;
  final String? rpcSessionId;
}

final class _AttachmentEffectFailed extends _AttachmentEvent {
  const _AttachmentEffectFailed({
    required this.effect,
    required this.error,
    required this.stackTrace,
  });

  final _AttachmentEffect effect;
  final Object error;
  final StackTrace stackTrace;
}

sealed class _AttachmentEffect implements RuntimeEffect {
  const _AttachmentEffect({required this.generation});

  final int generation;

  @override
  Object get key => 'workspace-attachment';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _AttachSession extends _AttachmentEffect {
  const _AttachSession({required super.generation});
}

final class _RecoverSession extends _AttachmentEffect {
  const _RecoverSession({
    required super.generation,
    required this.expiredSessionId,
  });

  final String expiredSessionId;
}

typedef WorkspaceAttachmentOperation = Future<void> Function();
typedef WorkspaceAttachmentRecovery =
    Future<void> Function(String expiredSessionId);

/// Single-flight child node for attach and expired-attachment recovery.
///
/// Futures are API waiters only. The durable facts and concurrency decision
/// live in [state], so a second caller joins the active operation instead of
/// replacing an ad-hoc `_attachInFlight` field.
final class WorkspaceAttachmentRuntimeController {
  WorkspaceAttachmentRuntimeController({
    required this.performAttach,
    required this.performRecovery,
    required this.currentRpcSessionId,
    required this.onStateChanged,
  }) {
    _machine =
        RuntimeMachine<
          WorkspaceAttachmentRuntimeState,
          _AttachmentEvent,
          _AttachmentEffect
        >(
          initialState: const WorkspaceAttachmentDetached(),
          reducer: _reduce,
          execute: _execute,
          mapEffectError: (effect, error, stackTrace) =>
              _AttachmentEffectFailed(
                effect: effect,
                error: error,
                stackTrace: stackTrace,
              ),
          onTransition: (transition) {
            onStateChanged(transition.current);
            _settleWaiters(transition.current);
          },
        );
    onStateChanged(_machine.state);
  }

  final WorkspaceAttachmentOperation performAttach;
  final WorkspaceAttachmentRecovery performRecovery;
  final String? Function() currentRpcSessionId;
  final void Function(WorkspaceAttachmentRuntimeState state) onStateChanged;

  late final RuntimeMachine<
    WorkspaceAttachmentRuntimeState,
    _AttachmentEvent,
    _AttachmentEffect
  >
  _machine;
  final List<Completer<void>> _waiters = [];

  WorkspaceAttachmentRuntimeState get state => _machine.state;
  bool get isBusy =>
      state is WorkspaceAttachmentAttaching ||
      state is WorkspaceAttachmentRecovering;

  Future<void> attach() {
    if (state is WorkspaceAttachmentAttached) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    _machine.dispatch(const _AttachRequested());
    _settleWaiters(state);
    return waiter.future;
  }

  Future<void> recover(String expiredSessionId) {
    final waiter = Completer<void>();
    _waiters.add(waiter);
    _machine.dispatch(_RecoveryRequested(expiredSessionId));
    _settleWaiters(state);
    return waiter.future;
  }

  Future<void> waitForSettled() {
    if (!isBusy) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void reset() => _machine.dispatch(const _AttachmentReset());

  RuntimeTransition<WorkspaceAttachmentRuntimeState, _AttachmentEffect> _reduce(
    WorkspaceAttachmentRuntimeState state,
    _AttachmentEvent event,
  ) {
    if (event is _AttachmentReset) {
      return RuntimeTransition(
        WorkspaceAttachmentDetached(generation: state.generation + 1),
        invalidateEffects: true,
      );
    }
    if (event is _AttachRequested) {
      if (state is WorkspaceAttachmentAttaching ||
          state is WorkspaceAttachmentRecovering ||
          state is WorkspaceAttachmentAttached) {
        return RuntimeTransition(state);
      }
      final generation = state.generation + 1;
      return RuntimeTransition(
        WorkspaceAttachmentAttaching(generation: generation),
        invalidateEffects: true,
        effects: [_AttachSession(generation: generation)],
      );
    }
    if (event case _RecoveryRequested(:final expiredSessionId)) {
      if (state is WorkspaceAttachmentRecovering ||
          state is WorkspaceAttachmentAttaching) {
        return RuntimeTransition(state);
      }
      final generation = state.generation + 1;
      return RuntimeTransition(
        WorkspaceAttachmentRecovering(
          generation: generation,
          expiredSessionId: expiredSessionId,
        ),
        invalidateEffects: true,
        effects: [
          _RecoverSession(
            generation: generation,
            expiredSessionId: expiredSessionId,
          ),
        ],
      );
    }
    if (event is _AttachmentCompleted) {
      if (event.generation != state.generation ||
          (state is! WorkspaceAttachmentAttaching &&
              state is! WorkspaceAttachmentRecovering)) {
        return RuntimeTransition(state);
      }
      return RuntimeTransition(
        WorkspaceAttachmentAttached(
          generation: event.generation,
          rpcSessionId: event.rpcSessionId,
        ),
      );
    }
    if (event is _AttachmentEffectFailed) {
      if (event.effect.generation != state.generation) {
        return RuntimeTransition(state);
      }
      return RuntimeTransition(
        WorkspaceAttachmentFailed(
          generation: state.generation,
          error: event.error,
          stackTrace: event.stackTrace,
        ),
      );
    }
    return RuntimeTransition(state);
  }

  Future<_AttachmentEvent?> _execute(
    _AttachmentEffect effect,
    RuntimeEffectContext context,
  ) async {
    switch (effect) {
      case _AttachSession(:final generation):
        await performAttach();
        if (!context.isCurrent) return null;
        return _AttachmentCompleted(
          generation: generation,
          rpcSessionId: currentRpcSessionId(),
        );
      case _RecoverSession(:final generation, :final expiredSessionId):
        await performRecovery(expiredSessionId);
        if (!context.isCurrent) return null;
        return _AttachmentCompleted(
          generation: generation,
          rpcSessionId: currentRpcSessionId(),
        );
    }
  }

  void _settleWaiters(WorkspaceAttachmentRuntimeState state) {
    if (state is WorkspaceAttachmentAttaching ||
        state is WorkspaceAttachmentRecovering) {
      return;
    }
    for (final waiter in _waiters) {
      if (waiter.isCompleted) continue;
      if (state is WorkspaceAttachmentFailed) {
        waiter.completeError(state.error, state.stackTrace);
      } else {
        waiter.complete();
      }
    }
    _waiters.clear();
  }

  void dispose() {
    _machine.dispose();
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }
}
