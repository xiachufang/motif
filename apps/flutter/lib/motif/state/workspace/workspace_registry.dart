import 'dart:collection';

import 'workspace_lifecycle_controller.dart';
import 'workspace_instance.dart';
import 'workspace_view_model.dart';

/// Runtime identity and retention index for workspace composition roots.
///
/// Observable membership lives in `WorkspaceRegistryViewModel`; runtime
/// resources deliberately use ordinary maps so sockets/controllers never enter
/// the state tree.
final class WorkspaceRegistry {
  final Map<String, WorkspaceInstance> _active = {};
  final LinkedHashMap<WorkspaceKey, WorkspaceInstance> _warm = LinkedHashMap();

  WorkspaceInstance? activeForServer(String serverId) => _active[serverId];

  WorkspaceInstance? instanceFor(WorkspaceKey key) {
    final active = _active[key.serverId];
    if (active?.key == key) return active;
    return _warm[key];
  }

  WorkspaceLifecycleController? lifecycleForServer(String serverId) =>
      _active[serverId]?.lifecycle;

  String? activeSessionForServer(String serverId) =>
      _active[serverId]?.key.session;

  Iterable<MapEntry<String, WorkspaceInstance>> get activeEntries =>
      _active.entries;

  Iterable<WorkspaceInstance> get instances sync* {
    yield* _active.values;
    yield* _warm.values;
  }

  Iterable<WorkspaceLifecycleController> get lifecycles =>
      instances.map((instance) => instance.lifecycle);

  Iterable<WorkspaceInstance> instancesForServer(String serverId) sync* {
    final active = _active[serverId];
    if (active != null) yield active;
    for (final entry in _warm.entries) {
      if (entry.key.serverId == serverId) yield entry.value;
    }
  }

  Iterable<WorkspaceLifecycleController> lifecyclesForServer(String serverId) =>
      instancesForServer(serverId).map((instance) => instance.lifecycle);

  void installActive(WorkspaceInstance instance) {
    _active[instance.key.serverId] = instance;
  }

  WorkspaceInstance? removeActive(String serverId) => _active.remove(serverId);

  WorkspaceInstance parkActive(WorkspaceKey key) {
    final instance = _active.remove(key.serverId);
    if (instance == null || instance.key != key) {
      throw StateError('No active workspace: $key');
    }
    _warm.remove(key);
    _warm[key] = instance;
    return instance;
  }

  WorkspaceInstance? activateWarm(WorkspaceKey key) {
    final instance = _warm.remove(key);
    if (instance != null) _active[key.serverId] = instance;
    return instance;
  }

  List<WorkspaceInstance> evictWarmBeyond(int limit) {
    final evicted = <WorkspaceInstance>[];
    while (_warm.length > limit) {
      final key = _warm.keys.first;
      evicted.add(_warm.remove(key)!);
    }
    return evicted;
  }

  List<WorkspaceInstance> removeDeletedServers(Set<String> liveIds) {
    final removed = <WorkspaceInstance>[];
    for (final id in _active.keys.toList()) {
      if (!liveIds.contains(id)) removed.add(_active.remove(id)!);
    }
    for (final key in _warm.keys.toList()) {
      if (!liveIds.contains(key.serverId)) removed.add(_warm.remove(key)!);
    }
    return removed;
  }
}
