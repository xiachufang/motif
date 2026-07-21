import 'dart:async';

import '../../../log/log.dart';
import '../../../models/motif_proto.dart';
import '../../../net/rpc_client.dart';
import '../../runtime/runtime_effect.dart';
import '../../runtime/runtime_machine.dart';
import 'view_runtime_state.dart';
import 'view_tabs_view_model.dart';

typedef ViewRpcCall =
    Future<Map<String, Object?>> Function(
      String method, [
      Map<String, Object?> params,
    ]);

final class ViewTransport {
  const ViewTransport({required this.isAvailable, required this.call});

  final bool Function() isAvailable;
  final ViewRpcCall call;
}

final class ViewProjectionCallbacks {
  const ViewProjectionCallbacks({
    required this.onTabsChanged,
    required this.onActiveChanged,
  });

  final void Function() onTabsChanged;
  final void Function() onActiveChanged;
}

sealed class _ViewRuntimeEvent {
  const _ViewRuntimeEvent();
}

final class _ActivationRequested extends _ViewRuntimeEvent {
  const _ActivationRequested({
    required this.viewId,
    required this.previousViewId,
    required this.awaitConfirmation,
  });

  final String? viewId;
  final String? previousViewId;
  final bool awaitConfirmation;
}

final class _ActivationSent extends _ViewRuntimeEvent {
  const _ActivationSent({required this.generation});

  final int generation;
}

final class _ActivationConfirmed extends _ViewRuntimeEvent {
  const _ActivationConfirmed(this.viewId);

  final String? viewId;
}

final class _ActivationCancelled extends _ViewRuntimeEvent {
  const _ActivationCancelled();
}

final class _PendingLocalChanged extends _ViewRuntimeEvent {
  const _PendingLocalChanged(this.viewId);

  final String? viewId;
}

final class _ActivationEffectFailed extends _ViewRuntimeEvent {
  const _ActivationEffectFailed({
    required this.effect,
    required this.error,
    required this.stackTrace,
  });

  final _SendViewActivation effect;
  final Object error;
  final StackTrace stackTrace;
}

final class _SendViewActivation implements RuntimeEffect {
  const _SendViewActivation({required this.generation, required this.viewId});

  final int generation;
  final String? viewId;

  @override
  Object get key => 'view-activation';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _ActivationWaiter {
  const _ActivationWaiter({required this.generation, required this.completer});

  final int generation;
  final Completer<void> completer;
}

/// Owns tab state and optimistic view commands for one workspace.
final class ViewController {
  ViewController({
    required this.viewModel,
    required this.transport,
    required this.callbacks,
  }) {
    _machine =
        RuntimeMachine<
          ViewRuntimeState,
          _ViewRuntimeEvent,
          _SendViewActivation
        >(
          initialState: const ViewRuntimeState.initial(),
          reducer: _reduce,
          execute: _execute,
          mapEffectError: (effect, error, stackTrace) =>
              _ActivationEffectFailed(
                effect: effect,
                error: error,
                stackTrace: stackTrace,
              ),
          onTransition: _onTransition,
        );
    viewModel.runtime = _machine.state;
  }

  final ViewTabsViewModel viewModel;
  final ViewTransport transport;
  final ViewProjectionCallbacks callbacks;
  late final RuntimeMachine<
    ViewRuntimeState,
    _ViewRuntimeEvent,
    _SendViewActivation
  >
  _machine;
  final List<_ActivationWaiter> _activationWaiters = [];

  ViewRuntimeState get runtimeState => _machine.state;
  bool get hasPendingActivation =>
      runtimeState.activation is ViewActivationPending;
  String? get pendingLocalViewId => runtimeState.pendingLocalViewId;

  set pendingLocalViewId(String? value) =>
      _machine.dispatch(_PendingLocalChanged(value));

  Future<void> activate(String? viewId) async {
    if (!transport.isAvailable()) {
      if (viewId != null) selectLocally(viewId);
      return;
    }
    final previous = viewModel.activeViewId;
    Log.i(
      'activate view requested previous=$previous next=$viewId',
      name: 'motif.view',
    );
    _machine.dispatch(
      _ActivationRequested(
        viewId: viewId,
        previousViewId: previous,
        awaitConfirmation: previous != viewId,
      ),
    );
    final generation = runtimeState.generation;
    final waiter = Completer<void>();
    _activationWaiters.add(
      _ActivationWaiter(generation: generation, completer: waiter),
    );
    _settleActivationWaiters(runtimeState);
    await waiter.future;
    Log.i(
      'activate view confirmed active=${viewModel.activeViewId}',
      name: 'motif.view',
    );
  }

  Future<void> close(String viewId) async {
    final index = viewModel.items.indexWhere((view) => view.id == viewId);
    if (index < 0) {
      if (transport.isAvailable()) {
        await transport.call('view.close', {'view_id': viewId});
      }
      return;
    }

    final previousItems = [...viewModel.items];
    final previousActiveViewId = viewModel.activeViewId;
    final previousPendingLocalViewId = pendingLocalViewId;
    final next = [...viewModel.items]..removeAt(index);
    var nextActiveViewId = viewModel.activeViewId;
    if (viewModel.activeViewId == viewId) {
      nextActiveViewId = next.isEmpty
          ? null
          : next[index.clamp(0, next.length - 1).toInt()].id;
    }
    if (pendingLocalViewId == viewId) pendingLocalViewId = nextActiveViewId;
    _replaceItems(next);
    viewModel.activeViewId = nextActiveViewId;
    callbacks.onTabsChanged();

    if (!transport.isAvailable()) return;
    try {
      await transport.call('view.close', {'view_id': viewId});
    } catch (_) {
      if (!viewModel.items.any((view) => view.id == viewId)) {
        _replaceItems(previousItems);
        viewModel.activeViewId = previousActiveViewId;
        pendingLocalViewId = previousPendingLocalViewId;
        callbacks.onTabsChanged();
      }
      rethrow;
    }
  }

  Future<void> move(String viewId, int toIndex) async {
    final fromIndex = viewModel.items.indexWhere((view) => view.id == viewId);
    if (fromIndex < 0 || viewModel.items.isEmpty) return;
    final targetIndex = toIndex.clamp(0, viewModel.items.length - 1).toInt();
    if (fromIndex == targetIndex) return;

    final previous = [...viewModel.items];
    final optimistic = _moved(viewId, targetIndex);
    _replaceItems(optimistic);
    if (!transport.isAvailable()) return;
    try {
      await transport.call('view.move', {
        'view_id': viewId,
        'to_index': targetIndex,
      });
    } catch (_) {
      if (_sameOrder(viewModel.items, optimistic)) _replaceItems(previous);
      rethrow;
    }
  }

  void selectLocally(String viewId) {
    if (!viewModel.items.any((view) => view.id == viewId)) return;
    viewModel.activeViewId = viewId;
    pendingLocalViewId = viewId;
  }

  Future<ViewInfo> open({required ViewSpec spec, bool activate = true}) async {
    if (!transport.isAvailable()) throw const RpcException('not connected');
    final body = await transport.call('view.open', {
      'spec': spec.toJson(),
      'activate': activate,
    });
    final view = ViewInfo.fromJson(
      (body['view'] as Map).cast<String, Object?>(),
    );
    if (!viewModel.items.any((candidate) => candidate.id == view.id)) {
      viewModel.items.add(view);
      callbacks.onTabsChanged();
    }
    return view;
  }

  void handleOpened(ViewInfo view) {
    if (!viewModel.items.any((candidate) => candidate.id == view.id)) {
      viewModel.items.add(view);
    }
    callbacks.onTabsChanged();
  }

  void handleClosed(String? id) {
    viewModel.items.removeWhere((view) => view.id == id);
    if (viewModel.activeViewId == id) viewModel.activeViewId = null;
    if (runtimeState.activation case ViewActivationPending(
      :final viewId,
    ) when viewId == id) {
      _machine.dispatch(const _ActivationCancelled());
    }
    callbacks.onTabsChanged();
  }

  void handleActiveChanged(String? id) {
    _machine.dispatch(_ActivationConfirmed(id));
  }

  void handleMoved(Iterable<String> order) {
    final byId = {for (final view in viewModel.items) view.id: view};
    _replaceItems([
      for (final id in order)
        if (byId[id] != null) byId[id]!,
    ]);
  }

  void replaceSnapshot(Iterable<ViewInfo> items, String? activeViewId) {
    completePendingActivation();
    _replaceItems(items);
    viewModel.activeViewId = activeViewId;
  }

  void clear() {
    completePendingActivation();
    viewModel.items.clear();
    viewModel.activeViewId = null;
  }

  void completePendingActivation() {
    if (hasPendingActivation) {
      _machine.dispatch(const _ActivationCancelled());
    }
  }

  RuntimeTransition<ViewRuntimeState, _SendViewActivation> _reduce(
    ViewRuntimeState state,
    _ViewRuntimeEvent event,
  ) {
    if (event case _PendingLocalChanged(:final viewId)) {
      return RuntimeTransition(
        state.copyWith(
          pendingLocalViewId: viewId,
          clearPendingLocalViewId: viewId == null,
        ),
      );
    }
    if (event is _ActivationRequested) {
      if (state.activation case ViewActivationPending(
        :final viewId,
      ) when viewId == event.viewId) {
        return RuntimeTransition(state);
      }
      final generation = state.generation + 1;
      return RuntimeTransition(
        state.copyWith(
          generation: generation,
          activation: ViewActivationPending(
            viewId: event.viewId,
            previousViewId: event.previousViewId,
            awaitConfirmation: event.awaitConfirmation,
          ),
          pendingLocalViewId: event.viewId,
          clearPendingLocalViewId: event.viewId == null,
        ),
        invalidateEffects: true,
        effects: [
          _SendViewActivation(generation: generation, viewId: event.viewId),
        ],
      );
    }
    if (event is _ActivationSent) {
      if (event.generation != state.generation ||
          state.activation is! ViewActivationPending) {
        return RuntimeTransition(state);
      }
      final pending = state.activation as ViewActivationPending;
      if (pending.awaitConfirmation) return RuntimeTransition(state);
      return RuntimeTransition(
        state.copyWith(
          activation: const ViewActivationIdle(),
          clearPendingLocalViewId: state.pendingLocalViewId == pending.viewId,
        ),
      );
    }
    if (event case _ActivationConfirmed(:final viewId)) {
      final activation = state.activation;
      if (activation is ViewActivationPending && activation.viewId != viewId) {
        return RuntimeTransition(state);
      }
      return RuntimeTransition(
        state.copyWith(
          activation: const ViewActivationIdle(),
          clearPendingLocalViewId: state.pendingLocalViewId == viewId,
        ),
        invalidateEffects: activation is ViewActivationPending,
      );
    }
    if (event is _ActivationCancelled) {
      final activation = state.activation;
      if (activation is! ViewActivationPending) return RuntimeTransition(state);
      return RuntimeTransition(
        state.copyWith(
          generation: state.generation + 1,
          activation: const ViewActivationIdle(),
          clearPendingLocalViewId:
              state.pendingLocalViewId == activation.viewId,
        ),
        invalidateEffects: true,
      );
    }
    if (event is _ActivationEffectFailed) {
      if (event.effect.generation != state.generation ||
          state.activation is! ViewActivationPending) {
        return RuntimeTransition(state);
      }
      final pending = state.activation as ViewActivationPending;
      return RuntimeTransition(
        state.copyWith(
          activation: ViewActivationFailed(
            viewId: pending.viewId,
            previousViewId: pending.previousViewId,
            error: event.error,
            stackTrace: event.stackTrace,
          ),
          clearPendingLocalViewId: state.pendingLocalViewId == pending.viewId,
        ),
      );
    }
    return RuntimeTransition(state);
  }

  Future<_ViewRuntimeEvent?> _execute(
    _SendViewActivation effect,
    RuntimeEffectContext context,
  ) async {
    await transport.call('view.activate', {'view_id': ?effect.viewId});
    if (!context.isCurrent) return null;
    return _ActivationSent(generation: effect.generation);
  }

  void _onTransition(
    RuntimeTransitionRecord<ViewRuntimeState, _ViewRuntimeEvent> transition,
  ) {
    viewModel.runtime = transition.current;
    switch (transition.event) {
      case _ActivationRequested(:final viewId):
        viewModel.activeViewId = viewId;
      case _ActivationConfirmed(:final viewId):
        final previousActivation = transition.previous.activation;
        if (previousActivation is! ViewActivationPending ||
            previousActivation.viewId == viewId) {
          viewModel.activeViewId = viewId;
          callbacks.onActiveChanged();
        }
      case _ActivationEffectFailed():
        final failed = transition.current.activation;
        if (failed is ViewActivationFailed &&
            viewModel.activeViewId == failed.viewId) {
          viewModel.activeViewId = failed.previousViewId;
        }
      default:
        break;
    }
    _settleActivationWaiters(transition.current);
  }

  void _settleActivationWaiters(ViewRuntimeState state) {
    final pendingGeneration = state.activation is ViewActivationPending
        ? state.generation
        : null;
    for (final waiter in _activationWaiters.toList()) {
      if (pendingGeneration == waiter.generation) continue;
      _activationWaiters.remove(waiter);
      if (waiter.completer.isCompleted) continue;
      if (state.activation case ViewActivationFailed(
        :final error,
        :final stackTrace,
      ) when waiter.generation == state.generation) {
        waiter.completer.completeError(error, stackTrace);
      } else {
        waiter.completer.complete();
      }
    }
  }

  void dispose() {
    _machine.dispose();
    for (final waiter in _activationWaiters) {
      if (!waiter.completer.isCompleted) waiter.completer.complete();
    }
    _activationWaiters.clear();
  }

  List<ViewInfo> _moved(String viewId, int toIndex) {
    final next = [...viewModel.items];
    final fromIndex = next.indexWhere((view) => view.id == viewId);
    if (fromIndex < 0 || next.isEmpty) return next;
    final view = next.removeAt(fromIndex);
    next.insert(toIndex.clamp(0, next.length).toInt(), view);
    return next;
  }

  bool _sameOrder(List<ViewInfo> left, List<ViewInfo> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index].id != right[index].id) return false;
    }
    return true;
  }

  void _replaceItems(Iterable<ViewInfo> items) {
    viewModel.items.replaceRange(0, viewModel.items.length, items);
  }
}
