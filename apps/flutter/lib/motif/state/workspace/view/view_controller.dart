import 'dart:async';

import '../../../log/log.dart';
import '../../../models/motif_proto.dart';
import '../../../net/rpc_client.dart';
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

final class _PendingViewActivation {
  _PendingViewActivation({required this.viewId, required this.previousViewId});

  final String? viewId;
  final String? previousViewId;
  final Completer<void> confirmed = Completer<void>();
}

/// Owns tab state and optimistic view commands for one workspace.
final class ViewController {
  ViewController({
    required this.viewModel,
    required this.transport,
    required this.callbacks,
  });

  final ViewTabsViewModel viewModel;
  final ViewTransport transport;
  final ViewProjectionCallbacks callbacks;
  _PendingViewActivation? _pendingActivation;
  String? pendingLocalViewId;

  bool get hasPendingActivation => _pendingActivation != null;

  Future<void> activate(String? viewId) async {
    if (!transport.isAvailable()) {
      if (viewId != null) selectLocally(viewId);
      return;
    }
    final currentPending = _pendingActivation;
    if (currentPending != null && currentPending.viewId == viewId) {
      await currentPending.confirmed.future;
      return;
    }
    final previous = viewModel.activeViewId;
    Log.i(
      'activate view requested previous=$previous next=$viewId',
      name: 'motif.view',
    );
    if (previous == viewId) {
      await transport.call('view.activate', {'view_id': ?viewId});
      return;
    }
    completePendingActivation();
    final activation = _PendingViewActivation(
      viewId: viewId,
      previousViewId: previous,
    );
    _pendingActivation = activation;
    pendingLocalViewId = viewId;
    viewModel.activeViewId = viewId;
    try {
      await transport.call('view.activate', {'view_id': ?viewId});
    } catch (_) {
      if (_pendingActivation != activation) return;
      _pendingActivation = null;
      if (!activation.confirmed.isCompleted) activation.confirmed.complete();
      if (pendingLocalViewId == viewId) pendingLocalViewId = null;
      if (viewModel.activeViewId == viewId) {
        viewModel.activeViewId = activation.previousViewId;
      }
      rethrow;
    }
    if (_pendingActivation == activation) {
      await activation.confirmed.future;
    }
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
    final pending = _pendingActivation;
    if (pending != null && pending.viewId == id) {
      _pendingActivation = null;
      if (pendingLocalViewId == id) pendingLocalViewId = null;
      if (!pending.confirmed.isCompleted) pending.confirmed.complete();
    }
    callbacks.onTabsChanged();
  }

  void handleActiveChanged(String? id) {
    final pending = _pendingActivation;
    if (pending != null && pending.viewId != id) return;
    if (pending != null) {
      _pendingActivation = null;
      if (pendingLocalViewId == id) pendingLocalViewId = null;
      if (!pending.confirmed.isCompleted) pending.confirmed.complete();
    }
    viewModel.activeViewId = id;
    callbacks.onActiveChanged();
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
    final pending = _pendingActivation;
    _pendingActivation = null;
    if (pending != null && !pending.confirmed.isCompleted) {
      pending.confirmed.complete();
    }
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
