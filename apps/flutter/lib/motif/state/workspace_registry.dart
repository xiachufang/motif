import 'motif_client.dart';
import 'server_connection_controller.dart';

typedef WorkspaceKey = ({String serverId, String session});

class WorkspaceSlot {
  const WorkspaceSlot({required this.client, required this.controller});

  final MotifClient client;
  final ServerConnectionController controller;
}

/// Owns the active and warm workspace indexes. Connection behavior remains in
/// the controller; this type centralizes identity, recency, and lookup rules.
class WorkspaceRegistry {
  final Map<String, WorkspaceSlot> _active = {};
  final Map<WorkspaceKey, WorkspaceSlot> _warm = {};
  final Map<String, String> _activeSession = {};

  MotifClient? clientForServer(String serverId) => _active[serverId]?.client;
  ServerConnectionController? controllerForServer(String serverId) =>
      _active[serverId]?.controller;
  String? activeSessionForServer(String serverId) => _activeSession[serverId];

  Iterable<MapEntry<String, MotifClient>> get primaryClientEntries sync* {
    for (final entry in _active.entries) {
      yield MapEntry(entry.key, entry.value.client);
    }
  }

  Iterable<MotifClient> get clients sync* {
    for (final slot in _active.values) {
      yield slot.client;
    }
    for (final slot in _warm.values) {
      yield slot.client;
    }
  }

  Iterable<ServerConnectionController> get controllers sync* {
    for (final slot in _active.values) {
      yield slot.controller;
    }
    for (final slot in _warm.values) {
      yield slot.controller;
    }
  }

  Iterable<MotifClient> clientsForServer(String serverId) sync* {
    final active = _active[serverId];
    if (active != null) yield active.client;
    for (final entry in _warm.entries) {
      if (entry.key.serverId == serverId) yield entry.value.client;
    }
  }

  Iterable<ServerConnectionController> controllersForServer(
    String serverId,
  ) sync* {
    final active = _active[serverId];
    if (active != null) yield active.controller;
    for (final entry in _warm.entries) {
      if (entry.key.serverId == serverId) yield entry.value.controller;
    }
  }

  void installActive(String serverId, WorkspaceSlot slot) {
    _active[serverId] = slot;
  }

  WorkspaceSlot parkActive(WorkspaceKey key) {
    final slot = _active.remove(key.serverId);
    if (slot == null) throw StateError('No active workspace: ${key.serverId}');
    _warm[key] = slot;
    return slot;
  }

  WorkspaceSlot? activateWarm(WorkspaceKey key) {
    final slot = _warm.remove(key);
    if (slot != null) _active[key.serverId] = slot;
    return slot;
  }

  void setActiveSession(String serverId, String? session) {
    if (session == null) {
      _activeSession.remove(serverId);
    } else {
      _activeSession[serverId] = session;
    }
  }

  List<(WorkspaceKey, WorkspaceSlot)> evictWarmBeyond(int limit) {
    final evicted = <(WorkspaceKey, WorkspaceSlot)>[];
    while (_warm.length > limit) {
      final key = _warm.keys.first;
      final slot = _warm.remove(key)!;
      evicted.add((key, slot));
    }
    return evicted;
  }

  List<(String, WorkspaceSlot)> removeDeletedServers(Set<String> liveIds) {
    final removed = <(String, WorkspaceSlot)>[];
    for (final id in _active.keys.toList()) {
      if (!liveIds.contains(id)) removed.add((id, _active.remove(id)!));
    }
    for (final key in _warm.keys.toList()) {
      if (!liveIds.contains(key.serverId)) {
        removed.add((key.serverId, _warm.remove(key)!));
      }
    }
    _activeSession.removeWhere((id, _) => !liveIds.contains(id));
    return removed;
  }

  String? serverIdForClient(MotifClient client) {
    for (final entry in _active.entries) {
      if (identical(entry.value.client, client)) return entry.key;
    }
    for (final entry in _warm.entries) {
      if (identical(entry.value.client, client)) return entry.key.serverId;
    }
    return null;
  }
}
