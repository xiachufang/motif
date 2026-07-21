import 'dart:async';
import 'dart:convert';

import '../../models/motif_proto.dart';
import '../../platform/push_crypto.dart';
import '../../platform/services.dart';
import 'device_controller.dart';
import '../persistence/stores.dart';

typedef PushSessionRequest =
    void Function({required String serverId, required String session});
typedef PushNotificationSink =
    void Function(String serverId, MotifNotification notification);
typedef PushServerEndpoint = ({
  String serverId,
  bool isLive,
  DeviceController device,
});

/// Coordinates process-wide push registration against server-scoped device
/// controllers. It never depends on a workspace connection or UI object.
final class PushCoordinator {
  PushCoordinator({
    required this.settings,
    required this.service,
    required this.activeServerId,
    required this.serverEndpoints,
    required this.serverExists,
    required this.showNotification,
    required this.requestOpenSession,
  });

  final PushSettingsStore settings;
  final PushService service;
  final String? Function() activeServerId;
  final Iterable<PushServerEndpoint> Function() serverEndpoints;
  final bool Function(String serverId) serverExists;
  final PushNotificationSink showNotification;
  final PushSessionRequest requestOpenSession;

  bool _handlerWired = false;
  final Map<String, String> _serverIdsByInstanceId = {};
  final Set<String> _liveServerIds = {};
  final Map<String, String> _deviceTokensByServerId = {};
  final Map<String, Future<void>> _registrationByServerId = {};

  void start() {
    _wireHandlers();
    unawaited(_drainPendingNotificationOpen());
  }

  void onSettingsChanged() {
    if (settings.enabled) {
      _registerLiveServers();
    } else {
      _disableForKnownServers();
    }
  }

  void onAppResumed() => onSettingsChanged();

  void onServerChanged(PushServerEndpoint endpoint) {
    final serverId = endpoint.serverId;
    final wasLive = _liveServerIds.contains(serverId);
    if (endpoint.isLive) {
      _liveServerIds.add(serverId);
      if (settings.enabled) {
        if (!wasLive) unawaited(_register(endpoint));
      } else {
        unawaited(_unregister(endpoint));
      }
      return;
    }
    _liveServerIds.remove(serverId);
  }

  void removeServer(String serverId) {
    _liveServerIds.remove(serverId);
    _deviceTokensByServerId.remove(serverId);
    _registrationByServerId.remove(serverId);
    _serverIdsByInstanceId.removeWhere((_, value) => value == serverId);
  }

  Future<void> registerForPush({String? serverId}) async {
    final targetId = serverId ?? activeServerId();
    if (targetId == null) return;
    final endpoint = serverEndpoints()
        .where((candidate) => candidate.serverId == targetId)
        .firstOrNull;
    if (endpoint != null) await _register(endpoint);
  }

  void dispose() {
    _serverIdsByInstanceId.clear();
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
        final serverId = _serverIdsByInstanceId[instanceId];
        if (serverId != null) {
          showNotification(
            serverId,
            MotifNotification(
              title: (obj['title'] as String?) ?? 'Motif',
              body: (obj['body'] as String?) ?? '',
              sessionId: sessionId,
              kind: kind,
            ),
          );
        }
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

    var serverId = _serverIdsByInstanceId[instanceId];
    final persisted = settings.serverIdForInstance(instanceId);
    if (serverId == null && persisted != null && serverExists(persisted)) {
      serverId = persisted;
    }
    if (serverId == null || serverId.isEmpty) return;
    requestOpenSession(serverId: serverId, session: sessionId);
  }

  Future<void> _register(PushServerEndpoint endpoint) {
    final existing = _registrationByServerId[endpoint.serverId];
    if (existing != null) return existing;
    final task = _doRegister(endpoint);
    _registrationByServerId[endpoint.serverId] = task;
    task.whenComplete(() {
      if (identical(_registrationByServerId[endpoint.serverId], task)) {
        _registrationByServerId.remove(endpoint.serverId);
      }
    });
    return task;
  }

  Future<void> _doRegister(PushServerEndpoint endpoint) async {
    if (!settings.enabled || !endpoint.isLive) return;
    _wireHandlers();
    try {
      final registration = await service.register(
        encKeyBase64: settings.encKeyBase64,
      );
      if (registration == null) return;
      final instanceId = await endpoint.device.register(
        deviceToken: registration.deviceToken,
        platform: registration.platform,
        encKeyBase64: registration.encKeyBase64,
        environment: registration.environment,
        appVersion: registration.appVersion,
        mutedSessions: settings.mutedSessions.toList(),
      );
      _deviceTokensByServerId[endpoint.serverId] = registration.deviceToken;
      if (instanceId != null && instanceId.isNotEmpty) {
        _serverIdsByInstanceId[instanceId] = endpoint.serverId;
        await settings.bindInstanceToServer(instanceId, endpoint.serverId);
      }
    } catch (_) {
      // Push is best-effort; never block server/session access.
    }
  }

  void _registerLiveServers() {
    if (!settings.enabled) return;
    for (final endpoint in serverEndpoints()) {
      if (endpoint.isLive) unawaited(_register(endpoint));
    }
  }

  Future<void> _unregister(PushServerEndpoint endpoint) async {
    final token = _deviceTokensByServerId[endpoint.serverId];
    _serverIdsByInstanceId.removeWhere(
      (_, value) => value == endpoint.serverId,
    );
    if (token == null || token.isEmpty || !endpoint.isLive) return;
    try {
      await endpoint.device.unregister(token);
    } catch (_) {
      return;
    }
    _deviceTokensByServerId.remove(endpoint.serverId);
  }

  void _disableForKnownServers() {
    for (final endpoint in serverEndpoints()) {
      if (endpoint.isLive) unawaited(_unregister(endpoint));
    }
    _serverIdsByInstanceId.clear();
    unawaited(service.unregister());
  }
}
