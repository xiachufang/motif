import 'dart:async';
import 'dart:convert';

import '../models/motif_proto.dart';
import '../platform/push_crypto.dart';
import '../platform/services.dart';
import 'motif_client.dart';
import 'stores.dart';

typedef PushSessionRequest =
    void Function({required String serverId, required String session});

/// Coordinates device registration and notification routing without making the
/// top-level app state own push-specific caches and lifecycle rules.
class PushCoordinator {
  PushCoordinator({
    required this.settings,
    required this.service,
    required this.activeClient,
    required this.primaryClients,
    required this.serverIdForClient,
    required this.serverExists,
    required this.requestOpenSession,
  });

  final PushSettingsStore settings;
  final PushService service;
  final MotifClient? Function() activeClient;
  final Iterable<MapEntry<String, MotifClient>> Function() primaryClients;
  final String? Function(MotifClient client) serverIdForClient;
  final bool Function(String serverId) serverExists;
  final PushSessionRequest requestOpenSession;

  bool _handlerWired = false;
  final Map<String, MotifClient> _clientsByInstanceId = {};
  final Set<String> _liveServerIds = {};
  final Map<String, String> _deviceTokensByServerId = {};
  final Map<String, Future<void>> _registrationByServerId = {};

  void start() {
    _wireHandlers();
    unawaited(_drainPendingNotificationOpen());
  }

  void onSettingsChanged() {
    if (settings.enabled) {
      _registerLiveClients();
    } else {
      _disableForKnownServers();
    }
  }

  void onAppResumed() => onSettingsChanged();

  void onClientChanged(
    String serverId,
    MotifClient client, {
    required bool anyClientLiveForServer,
  }) {
    final wasLive = _liveServerIds.contains(serverId);
    if (client.isLive) {
      _liveServerIds.add(serverId);
      if (settings.enabled) {
        if (!wasLive) unawaited(_register(serverId, client));
      } else {
        unawaited(_unregister(serverId, client));
      }
      return;
    }

    if (!anyClientLiveForServer) _liveServerIds.remove(serverId);
    removeClient(client);
  }

  void removeClient(MotifClient client) {
    _clientsByInstanceId.removeWhere((_, value) => identical(value, client));
  }

  void removeServer(String serverId) {
    _liveServerIds.remove(serverId);
    _deviceTokensByServerId.remove(serverId);
    _registrationByServerId.remove(serverId);
    _clientsByInstanceId.removeWhere(
      (_, client) => serverIdForClient(client) == serverId,
    );
  }

  Future<void> registerForPush({MotifClient? client}) async {
    final target = client ?? activeClient();
    if (target == null) return;
    final serverId = serverIdForClient(target);
    if (serverId != null) {
      await _register(serverId, target);
    } else {
      await _doRegister(null, target);
    }
  }

  void dispose() {
    _clientsByInstanceId.clear();
    _liveServerIds.clear();
    _deviceTokensByServerId.clear();
    _registrationByServerId.clear();
  }

  void _wireHandlers() {
    if (_handlerWired) return;
    _handlerWired = true;
    service.onEncryptedPayload((e, n) async {
      final plain = await decryptPushPayload(
        encKeyB64: settings.encKeyBase64,
        eB64: e,
        nB64: n,
      );
      if (plain == null) return;
      try {
        final obj = jsonDecode(plain) as Map<String, Object?>;
        final motif = (obj['motif'] as Map).cast<String, Object?>();
        final instanceId = motif['instance_id'] as String;
        final sessionId = motif['session_id'] as String?;
        final kind = motif['kind'] as String;
        if (settings.isMuted(sessionId ?? '')) return;
        final target = _clientsByInstanceId[instanceId];
        target?.showNotification(
          MotifNotification(
            title: (obj['title'] as String?) ?? 'Motif',
            body: (obj['body'] as String?) ?? '',
            sessionId: sessionId,
            kind: kind,
          ),
        );
      } catch (_) {}
    });
    service.onNotificationOpen(({session, instanceId}) {
      _openSessionFromNotification(session: session, instanceId: instanceId);
    });
  }

  Future<void> _drainPendingNotificationOpen() async {
    try {
      final pending = await service.takePendingNotificationOpen();
      if (pending == null) return;
      _openSessionFromNotification(
        session: pending.session,
        instanceId: pending.instanceId,
      );
    } catch (_) {}
  }

  void _openSessionFromNotification({
    required String? session,
    String? instanceId,
  }) {
    final sessionId = session?.trim();
    if (sessionId == null ||
        sessionId.isEmpty ||
        instanceId == null ||
        instanceId.isEmpty ||
        settings.isMuted(sessionId)) {
      return;
    }

    final client = _clientsByInstanceId[instanceId];
    var serverId = client == null ? null : serverIdForClient(client);
    final persisted = settings.serverIdForInstance(instanceId);
    if (serverId == null && persisted != null && serverExists(persisted)) {
      serverId = persisted;
    }
    if (serverId == null || serverId.isEmpty) return;
    requestOpenSession(serverId: serverId, session: sessionId);
  }

  Future<void> _register(String serverId, MotifClient client) {
    final existing = _registrationByServerId[serverId];
    if (existing != null) return existing;
    final task = _doRegister(serverId, client);
    _registrationByServerId[serverId] = task;
    task.whenComplete(() {
      if (identical(_registrationByServerId[serverId], task)) {
        _registrationByServerId.remove(serverId);
      }
    });
    return task;
  }

  Future<void> _doRegister(String? serverId, MotifClient target) async {
    if (!settings.enabled || !target.isLive) return;
    _wireHandlers();
    try {
      final reg = await service.register(encKeyBase64: settings.encKeyBase64);
      if (reg == null) return;
      final instanceId = await target.registerDevice(
        deviceToken: reg.deviceToken,
        platform: reg.platform,
        encKeyBase64: reg.encKeyBase64,
        environment: reg.environment,
        appVersion: reg.appVersion,
        mutedSessions: settings.mutedSessions.toList(),
      );
      if (serverId != null) {
        _deviceTokensByServerId[serverId] = reg.deviceToken;
      }
      if (instanceId != null && instanceId.isNotEmpty) {
        _clientsByInstanceId[instanceId] = target;
        if (serverId != null) {
          await settings.bindInstanceToServer(instanceId, serverId);
        }
      }
    } catch (_) {
      // Push is best-effort; never block the session on it.
    }
  }

  void _registerLiveClients() {
    if (!settings.enabled) return;
    for (final entry in primaryClients()) {
      if (entry.value.isLive) unawaited(_register(entry.key, entry.value));
    }
  }

  Future<void> _unregister(String serverId, MotifClient client) async {
    final token = _deviceTokensByServerId[serverId];
    removeClient(client);
    if (token == null || token.isEmpty || !client.isLive) return;
    try {
      await client.unregisterDevice(token);
    } catch (_) {
      return;
    }
    _deviceTokensByServerId.remove(serverId);
  }

  void _disableForKnownServers() {
    for (final entry in primaryClients()) {
      if (entry.value.isLive) unawaited(_unregister(entry.key, entry.value));
    }
    _clientsByInstanceId.clear();
    unawaited(service.unregister());
  }
}
