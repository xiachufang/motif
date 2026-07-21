import 'dart:async';

import '../../runtime/runtime_effect.dart';
import '../../runtime/runtime_machine.dart';

enum RemotePortOperationKind {
  refresh,
  add,
  update,
  remove,
  open,
  stop,
  stopAll,
}

final class RemotePortQueuedOperation {
  const RemotePortQueuedOperation({required this.id, required this.kind});

  final int id;
  final RemotePortOperationKind kind;
}

sealed class RemotePortRuntimeState {
  const RemotePortRuntimeState({
    required this.generation,
    required this.requestSequence,
  });

  final int generation;
  final int requestSequence;
}

final class RemotePortRuntimeIdle extends RemotePortRuntimeState {
  const RemotePortRuntimeIdle({
    super.generation = 0,
    super.requestSequence = 0,
  });
}

final class RemotePortRuntimeRunning extends RemotePortRuntimeState {
  const RemotePortRuntimeRunning({
    required super.generation,
    required super.requestSequence,
    required this.active,
    required this.queued,
  });

  final RemotePortQueuedOperation active;
  final List<RemotePortQueuedOperation> queued;
}

final class RemotePortRuntimeReady extends RemotePortRuntimeState {
  const RemotePortRuntimeReady({
    required super.generation,
    required super.requestSequence,
  });
}

final class RemotePortRuntimeFailed extends RemotePortRuntimeState {
  const RemotePortRuntimeFailed({
    required super.generation,
    required super.requestSequence,
    required this.operation,
    required this.error,
    required this.stackTrace,
  });

  final RemotePortQueuedOperation operation;
  final Object error;
  final StackTrace stackTrace;
}

sealed class _RemotePortEvent {
  const _RemotePortEvent();
}

final class _OperationRequested extends _RemotePortEvent {
  const _OperationRequested(this.operation);

  final RemotePortQueuedOperation operation;
}

final class _OperationCompleted extends _RemotePortEvent {
  const _OperationCompleted({required this.operation, required this.result});

  final RemotePortQueuedOperation operation;
  final Object? result;
}

final class _OperationFailed extends _RemotePortEvent {
  const _OperationFailed({
    required this.effect,
    required this.error,
    required this.stackTrace,
  });

  final _ExecuteOperation effect;
  final Object error;
  final StackTrace stackTrace;
}

final class _ExecuteOperation implements RuntimeEffect {
  const _ExecuteOperation(this.operation);

  final RemotePortQueuedOperation operation;

  @override
  Object get key => 'remote-port-control';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.droppable;
}

final class _RemotePortOperationRecord {
  const _RemotePortOperationRecord({
    required this.execute,
    required this.completer,
  });

  final Future<Object?> Function() execute;
  final Completer<Object?> completer;
}

/// Serial command child node for remote-port mappings and forwarder resources.
final class RemotePortRuntimeController {
  RemotePortRuntimeController({required this.onStateChanged}) {
    _machine =
        RuntimeMachine<
          RemotePortRuntimeState,
          _RemotePortEvent,
          _ExecuteOperation
        >(
          initialState: const RemotePortRuntimeIdle(),
          reducer: _reduce,
          execute: _execute,
          mapEffectError: (effect, error, stackTrace) => _OperationFailed(
            effect: effect,
            error: error,
            stackTrace: stackTrace,
          ),
          onTransition: (transition) {
            _settleOperation(transition.event);
            onStateChanged(transition.current);
          },
        );
    onStateChanged(_machine.state);
  }

  final void Function(RemotePortRuntimeState state) onStateChanged;
  late final RuntimeMachine<
    RemotePortRuntimeState,
    _RemotePortEvent,
    _ExecuteOperation
  >
  _machine;
  final Map<int, _RemotePortOperationRecord> _operations = {};

  RemotePortRuntimeState get state => _machine.state;

  Future<T> run<T>(
    RemotePortOperationKind kind,
    Future<T> Function() operation,
  ) async {
    final id = state.requestSequence + 1;
    final completer = Completer<Object?>();
    _operations[id] = _RemotePortOperationRecord(
      execute: () => operation(),
      completer: completer,
    );
    _machine.dispatch(
      _OperationRequested(RemotePortQueuedOperation(id: id, kind: kind)),
    );
    return (await completer.future) as T;
  }

  RuntimeTransition<RemotePortRuntimeState, _ExecuteOperation> _reduce(
    RemotePortRuntimeState state,
    _RemotePortEvent event,
  ) {
    if (event case _OperationRequested(:final operation)) {
      if (state is RemotePortRuntimeRunning) {
        return RuntimeTransition(
          RemotePortRuntimeRunning(
            generation: state.generation,
            requestSequence: operation.id,
            active: state.active,
            queued: List<RemotePortQueuedOperation>.unmodifiable([
              ...state.queued,
              operation,
            ]),
          ),
        );
      }
      return RuntimeTransition(
        RemotePortRuntimeRunning(
          generation: state.generation + 1,
          requestSequence: operation.id,
          active: operation,
          queued: const [],
        ),
        effects: [_ExecuteOperation(operation)],
      );
    }
    if (event is _OperationCompleted) {
      if (state is! RemotePortRuntimeRunning ||
          state.active.id != event.operation.id) {
        return RuntimeTransition(state);
      }
      return _advance(state);
    }
    if (event is _OperationFailed) {
      if (state is! RemotePortRuntimeRunning ||
          state.active.id != event.effect.operation.id) {
        return RuntimeTransition(state);
      }
      if (state.queued.isNotEmpty) return _advance(state);
      return RuntimeTransition(
        RemotePortRuntimeFailed(
          generation: state.generation,
          requestSequence: state.requestSequence,
          operation: state.active,
          error: event.error,
          stackTrace: event.stackTrace,
        ),
      );
    }
    return RuntimeTransition(state);
  }

  RuntimeTransition<RemotePortRuntimeState, _ExecuteOperation> _advance(
    RemotePortRuntimeRunning state,
  ) {
    if (state.queued.isEmpty) {
      return RuntimeTransition(
        RemotePortRuntimeReady(
          generation: state.generation,
          requestSequence: state.requestSequence,
        ),
      );
    }
    final next = state.queued.first;
    return RuntimeTransition(
      RemotePortRuntimeRunning(
        generation: state.generation + 1,
        requestSequence: state.requestSequence,
        active: next,
        queued: List<RemotePortQueuedOperation>.unmodifiable(
          state.queued.skip(1),
        ),
      ),
      effects: [_ExecuteOperation(next)],
    );
  }

  Future<_RemotePortEvent?> _execute(
    _ExecuteOperation effect,
    RuntimeEffectContext context,
  ) async {
    final record = _operations[effect.operation.id];
    if (record == null) return null;
    final result = await record.execute();
    if (!context.isCurrent) return null;
    return _OperationCompleted(operation: effect.operation, result: result);
  }

  void _settleOperation(_RemotePortEvent event) {
    switch (event) {
      case _OperationCompleted(:final operation, :final result):
        _operations.remove(operation.id)?.completer.complete(result);
      case _OperationFailed(
        effect: _ExecuteOperation(:final operation),
        :final error,
        :final stackTrace,
      ):
        _operations
            .remove(operation.id)
            ?.completer
            .completeError(error, stackTrace);
      default:
        break;
    }
  }

  void dispose() {
    _machine.dispose();
    for (final record in _operations.values) {
      if (!record.completer.isCompleted) record.completer.complete();
    }
    _operations.clear();
  }
}
