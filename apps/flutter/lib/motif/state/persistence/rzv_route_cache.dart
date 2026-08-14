import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/settings.dart';
import 'serialization.dart';

/// A non-sensitive, best-effort cache of the last LAN route advertised by a
/// rendezvous server.
///
/// Entries are bound to the pairing relay and certificate pin. Re-pairing the
/// same server id therefore cannot accidentally reuse an old route. The
/// certificate pin and PSK bearer still authenticate every direct connection;
/// this cache is only a latency hint.
final class RzvRouteCache {
  RzvRouteCache.memory() : _prefs = null;

  RzvRouteCache.persistent(SharedPreferences prefs) : _prefs = prefs {
    final decoded = jsonDecodeMap(prefs.getString(_storageKey) ?? '');
    if (decoded == null) return;
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final hint = RzvRouteHint.fromJson(
        entry.key,
        value.cast<String, Object?>(),
      );
      if (hint != null) _entries[entry.key] = hint;
    }
  }

  static const _storageKey = 'motif.rzvRoutes.v1';

  final SharedPreferences? _prefs;
  final Map<String, RzvRouteHint> _entries = {};
  Future<void> _pendingWrite = Future<void>.value();

  RzvRouteHint? lookup(MotifServer server) {
    final hint = _entries[server.id];
    if (hint == null) return null;
    if (server.kind != ServerKind.rendezvous ||
        hint.relay != server.relay ||
        hint.pubKey != server.pubKey) {
      _entries.remove(server.id);
      _schedulePersist();
      return null;
    }
    return hint;
  }

  /// Update advertised candidates while preserving the last successful host
  /// when it is still present.
  void rememberCandidates(
    MotifServer server, {
    required int port,
    required List<String> addrs,
  }) {
    if (server.kind != ServerKind.rendezvous || port <= 0 || addrs.isEmpty) {
      return;
    }
    final normalized = addrs.toSet().toList(growable: false);
    final previous = lookup(server);
    final lastSuccessfulHost = normalized.contains(previous?.lastSuccessfulHost)
        ? previous!.lastSuccessfulHost
        : null;
    _entries[server.id] = RzvRouteHint(
      serverId: server.id,
      relay: server.relay,
      pubKey: server.pubKey,
      port: port,
      addrs: normalized,
      lastSuccessfulHost: lastSuccessfulHost,
      updatedAt: DateTime.now(),
    );
    _schedulePersist();
  }

  void rememberSuccess(MotifServer server, String host) {
    final previous = lookup(server);
    if (previous == null || !previous.addrs.contains(host)) return;
    _entries[server.id] = previous.copyWith(
      lastSuccessfulHost: host,
      updatedAt: DateTime.now(),
    );
    _schedulePersist();
  }

  void remove(String serverId) {
    if (_entries.remove(serverId) != null) _schedulePersist();
  }

  void retain(Set<String> serverIds) {
    final before = _entries.length;
    _entries.removeWhere((serverId, _) => !serverIds.contains(serverId));
    if (_entries.length != before) _schedulePersist();
  }

  Future<void> flush() => _pendingWrite;

  void _schedulePersist() {
    final prefs = _prefs;
    if (prefs == null) return;
    final snapshot = jsonEncodeMap({
      for (final entry in _entries.entries) entry.key: entry.value.toJson(),
    });
    _pendingWrite = _pendingWrite.then((_) async {
      await prefs.setString(_storageKey, snapshot);
    });
  }
}

final class RzvRouteHint {
  const RzvRouteHint({
    required this.serverId,
    required this.relay,
    required this.pubKey,
    required this.port,
    required this.addrs,
    required this.updatedAt,
    this.lastSuccessfulHost,
  });

  final String serverId;
  final String relay;
  final String pubKey;
  final int port;
  final List<String> addrs;
  final String? lastSuccessfulHost;
  final DateTime updatedAt;

  List<String> get orderedAddrs {
    final preferred = lastSuccessfulHost;
    if (preferred == null || !addrs.contains(preferred)) return addrs;
    return [preferred, ...addrs.where((addr) => addr != preferred)];
  }

  RzvRouteHint copyWith({String? lastSuccessfulHost, DateTime? updatedAt}) =>
      RzvRouteHint(
        serverId: serverId,
        relay: relay,
        pubKey: pubKey,
        port: port,
        addrs: addrs,
        lastSuccessfulHost: lastSuccessfulHost ?? this.lastSuccessfulHost,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
    'relay': relay,
    'pubKey': pubKey,
    'port': port,
    'addrs': addrs,
    if (lastSuccessfulHost != null) 'lastSuccessfulHost': lastSuccessfulHost,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static RzvRouteHint? fromJson(String serverId, Map<String, Object?> json) {
    final relay = json['relay'];
    final pubKey = json['pubKey'];
    final port = json['port'];
    final addrs = (json['addrs'] as List?)?.whereType<String>().toList();
    final updatedAt = DateTime.tryParse('${json['updatedAt'] ?? ''}');
    if (relay is! String ||
        pubKey is! String ||
        port is! num ||
        port <= 0 ||
        port > 65535 ||
        addrs == null ||
        addrs.isEmpty ||
        updatedAt == null) {
      return null;
    }
    final lastSuccessfulHost = json['lastSuccessfulHost'];
    return RzvRouteHint(
      serverId: serverId,
      relay: relay,
      pubKey: pubKey,
      port: port.toInt(),
      addrs: addrs,
      lastSuccessfulHost: lastSuccessfulHost is String
          ? lastSuccessfulHost
          : null,
      updatedAt: updatedAt,
    );
  }
}
