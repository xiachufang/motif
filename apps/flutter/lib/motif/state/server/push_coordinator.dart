import 'dart:async';
import 'dart:convert';

import '../../models/motif_proto.dart';
import '../../platform/push_crypto.dart';
import '../../platform/services.dart';
import '../persistence/stores.dart';
import '../runtime/runtime_effect.dart';
import '../runtime/runtime_machine.dart';
import 'device_controller.dart';
import 'push_runtime_state.dart';

typedef PushSessionRequest =
    void Function({
      required String serverId,
      required String session,
      String? viewId,
    });
typedef PushNotificationSink =
    void Function(String serverId, MotifNotification notification);
typedef PushServerEndpoint = ({
  String serverId,
  bool isLive,
  DeviceController device,
});

sealed class _PushEvent {
  const _PushEvent();
}

final class _StartRequested extends _PushEvent {
  const _StartRequested(this.enabled);

  final bool enabled;
}

final class _SettingsChanged extends _PushEvent {
  const _SettingsChanged({required this.enabled, required this.force});

  final bool enabled;
  final bool force;
}

final class _ServerChanged extends _PushEvent {
  const _ServerChanged({required this.serverId, required this.live});

  final String serverId;
  final bool live;
}

final class _ManualRegisterRequested extends _PushEvent {
  const _ManualRegisterRequested(this.serverId);

  final String serverId;
}

final class _ServerRemoved extends _PushEvent {
  const _ServerRemoved(this.serverId);

  final String serverId;
}

final class _HandlersWired extends _PushEvent {
  const _HandlersWired(this.pendingOpen);

  final ({String? session, String? instanceId, String? viewId})? pendingOpen;
}

final class _ServerRegistered extends _PushEvent {
  const _ServerRegistered({
    required this.serverId,
    required this.deviceToken,
    required this.instanceId,
  });

  final String serverId;
  final String deviceToken;
  final String? instanceId;
}

final class _ServerUnregistered extends _PushEvent {
  const _ServerUnregistered(this.serverId);

  final String serverId;
}

final class _EncryptedPayloadReceived extends _PushEvent {
  const _EncryptedPayloadReceived(this.e, this.n);

  final String e;
  final String n;
}

final class _NotificationOpenReceived extends _PushEvent {
  const _NotificationOpenReceived({
    required this.session,
    this.instanceId,
    this.viewId,
  });

  final String? session;
  final String? instanceId;
  final String? viewId;
}

final class _ForegroundNotificationDecoded extends _PushEvent {
  const _ForegroundNotificationDecoded({
    required this.serverId,
    required this.notification,
  });

  final String serverId;
  final MotifNotification notification;
}

final class _PushEffectFailed extends _PushEvent {
  const _PushEffectFailed({
    required this.effect,
    required this.error,
    required this.stackTrace,
  });

  final _PushEffect effect;
  final Object error;
  final StackTrace stackTrace;
}

sealed class _PushEffect implements RuntimeEffect {
  const _PushEffect();
}

final class _WireHandlers extends _PushEffect {
  const _WireHandlers();

  @override
  Object get key => 'push-handlers';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.droppable;
}

sealed class _PushServerEffect extends _PushEffect {
  const _PushServerEffect(this.serverId);

  final String serverId;

  @override
  Object get key => 'push-server:$serverId';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _RegisterServer extends _PushServerEffect {
  const _RegisterServer(super.serverId);
}

final class _UnregisterServer extends _PushServerEffect {
  const _UnregisterServer(super.serverId, this.deviceToken);

  final String deviceToken;
}

final class _CancelServerWork extends _PushServerEffect {
  const _CancelServerWork(super.serverId);
}

final class _UnregisterPlatform extends _PushEffect {
  const _UnregisterPlatform();

  @override
  Object get key => 'push-platform';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _DecodeEncryptedPayload extends _PushEffect {
  const _DecodeEncryptedPayload({
    required this.e,
    required this.n,
    required this.serverIdsByInstanceId,
  });

  final String e;
  final String n;
  final Map<String, String> serverIdsByInstanceId;

  @override
  Object get key => Object();

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.parallel;
}

/// Process-wide push registration and routing state machine.
final class PushCoordinator {
  PushCoordinator({
    required this.settings,
    required this.service,
    required this.activeServerId,
    required this.serverEndpoints,
    required this.serverExists,
    required this.showNotification,
    required this.requestOpenSession,
  }) {
    _machine = RuntimeMachine<PushRuntimeState, _PushEvent, _PushEffect>(
      initialState: const PushRuntimeState.initial(),
      reducer: _reduce,
      execute: _execute,
      mapEffectError: (effect, error, stackTrace) => _PushEffectFailed(
        effect: effect,
        error: error,
        stackTrace: stackTrace,
      ),
      onTransition: _onTransition,
    );
    settings.viewModel.runtime = _machine.state;
  }

  final PushSettingsStore settings;
  final PushService service;
  final String? Function() activeServerId;
  final Iterable<PushServerEndpoint> Function() serverEndpoints;
  final bool Function(String serverId) serverExists;
  final PushNotificationSink showNotification;
  final PushSessionRequest requestOpenSession;

  late final RuntimeMachine<PushRuntimeState, _PushEvent, _PushEffect> _machine;
  final Map<String, List<Completer<void>>> _registrationWaiters = {};

  PushRuntimeState get runtimeState => _machine.state;

  void start() => _machine.dispatch(_StartRequested(settings.enabled));

  void onSettingsChanged() => _machine.dispatch(
    _SettingsChanged(enabled: settings.enabled, force: false),
  );

  void onAppResumed() => _machine.dispatch(
    _SettingsChanged(enabled: settings.enabled, force: true),
  );

  void onServerChanged(PushServerEndpoint endpoint) => _machine.dispatch(
    _ServerChanged(serverId: endpoint.serverId, live: endpoint.isLive),
  );

  void removeServer(String serverId) =>
      _machine.dispatch(_ServerRemoved(serverId));

  Future<void> registerForPush({String? serverId}) {
    final targetId = serverId ?? activeServerId();
    if (targetId == null) return Future<void>.value();
    final waiter = Completer<void>();
    _registrationWaiters.putIfAbsent(targetId, () => []).add(waiter);
    _machine.dispatch(_ManualRegisterRequested(targetId));
    _settleRegistrationWaiters(runtimeState);
    return waiter.future;
  }

  RuntimeTransition<PushRuntimeState, _PushEffect> _reduce(
    PushRuntimeState state,
    _PushEvent event,
  ) {
    if (event case _StartRequested(:final enabled)) {
      if (state.handlers is! PushHandlersDormant) {
        return RuntimeTransition(state.copyWith(enabled: enabled));
      }
      return RuntimeTransition(
        state.copyWith(enabled: enabled, handlers: const PushHandlersWiring()),
        effects: [const _WireHandlers()],
      );
    }

    if (event case _SettingsChanged(:final enabled, :final force)) {
      final servers = Map<String, PushServerRuntimeState>.from(state.servers);
      final effects = <_PushEffect>[];
      for (final entry in servers.entries.toList()) {
        final server = entry.value;
        if (!server.live) continue;
        if (enabled) {
          if (!force && server.registration is PushServerRegistering) continue;
          servers[entry.key] = server.copyWith(
            registration: PushServerRegistering(
              previousDeviceToken: _deviceToken(server.registration),
            ),
          );
          effects.add(_RegisterServer(entry.key));
        } else {
          final token = _deviceToken(server.registration);
          if (token != null && token.isNotEmpty) {
            servers[entry.key] = server.copyWith(
              registration: PushServerUnregistering(deviceToken: token),
            );
            effects.add(_UnregisterServer(entry.key, token));
          } else if (server.registration is PushServerRegistering) {
            servers[entry.key] = server.copyWith(
              registration: const PushServerIdle(),
            );
            effects.add(_CancelServerWork(entry.key));
          }
        }
      }
      return RuntimeTransition(
        state.copyWith(
          generation: state.generation + 1,
          enabled: enabled,
          servers: Map<String, PushServerRuntimeState>.unmodifiable(servers),
          serverIdsByInstanceId: enabled
              ? state.serverIdsByInstanceId
              : const {},
        ),
        effects: [...effects, if (!enabled) const _UnregisterPlatform()],
      );
    }

    if (event case _ServerChanged(:final serverId, :final live)) {
      final previous = state.servers[serverId];
      final wasLive = previous?.live ?? false;
      var server =
          (previous ??
                  const PushServerRuntimeState(
                    live: false,
                    registration: PushServerIdle(),
                  ))
              .copyWith(live: live);
      final effects = <_PushEffect>[];
      if (live && !wasLive) {
        if (state.enabled) {
          server = server.copyWith(
            registration: PushServerRegistering(
              previousDeviceToken: _deviceToken(server.registration),
            ),
          );
          effects.add(_RegisterServer(serverId));
        } else {
          final token = _deviceToken(server.registration);
          if (token != null && token.isNotEmpty) {
            server = server.copyWith(
              registration: PushServerUnregistering(deviceToken: token),
            );
            effects.add(_UnregisterServer(serverId, token));
          }
        }
      } else if (!live &&
          wasLive &&
          server.registration is PushServerRegistering) {
        server = server.copyWith(
          registration: _registrationBeforeRetry(
            state,
            serverId,
            server.registration as PushServerRegistering,
          ),
        );
        effects.add(_CancelServerWork(serverId));
      }
      return RuntimeTransition(
        state.copyWith(
          servers: Map<String, PushServerRuntimeState>.unmodifiable({
            ...state.servers,
            serverId: server,
          }),
        ),
        effects: effects,
      );
    }

    if (event case _ManualRegisterRequested(:final serverId)) {
      final server = state.servers[serverId];
      if (!state.enabled || server == null || !server.live) {
        return RuntimeTransition(state);
      }
      if (server.registration is PushServerRegistering) {
        return RuntimeTransition(state);
      }
      return RuntimeTransition(
        state.copyWith(
          servers: Map<String, PushServerRuntimeState>.unmodifiable({
            ...state.servers,
            serverId: server.copyWith(
              registration: PushServerRegistering(
                previousDeviceToken: _deviceToken(server.registration),
              ),
            ),
          }),
        ),
        effects: [_RegisterServer(serverId)],
      );
    }

    if (event case _ServerRemoved(:final serverId)) {
      final servers = Map<String, PushServerRuntimeState>.from(state.servers)
        ..remove(serverId);
      final mappings = Map<String, String>.from(state.serverIdsByInstanceId)
        ..removeWhere((_, value) => value == serverId);
      return RuntimeTransition(
        state.copyWith(
          servers: Map<String, PushServerRuntimeState>.unmodifiable(servers),
          serverIdsByInstanceId: Map<String, String>.unmodifiable(mappings),
        ),
        effects: [_CancelServerWork(serverId)],
      );
    }

    if (event is _HandlersWired) {
      return RuntimeTransition(
        state.copyWith(handlers: const PushHandlersReady()),
      );
    }

    if (event case _ServerRegistered(
      :final serverId,
      :final deviceToken,
      :final instanceId,
    )) {
      final server = state.servers[serverId];
      if (!state.enabled ||
          server == null ||
          !server.live ||
          server.registration is! PushServerRegistering) {
        return RuntimeTransition(state);
      }
      final mappings = Map<String, String>.from(state.serverIdsByInstanceId);
      if (instanceId != null && instanceId.isNotEmpty) {
        mappings[instanceId] = serverId;
      }
      return RuntimeTransition(
        state.copyWith(
          servers: Map<String, PushServerRuntimeState>.unmodifiable({
            ...state.servers,
            serverId: server.copyWith(
              registration: PushServerRegistered(
                deviceToken: deviceToken,
                instanceId: instanceId,
              ),
            ),
          }),
          serverIdsByInstanceId: Map<String, String>.unmodifiable(mappings),
        ),
      );
    }

    if (event case _ServerUnregistered(:final serverId)) {
      final server = state.servers[serverId];
      if (server == null) return RuntimeTransition(state);
      final mappings = Map<String, String>.from(state.serverIdsByInstanceId)
        ..removeWhere((_, value) => value == serverId);
      return RuntimeTransition(
        state.copyWith(
          servers: Map<String, PushServerRuntimeState>.unmodifiable({
            ...state.servers,
            serverId: server.copyWith(registration: const PushServerIdle()),
          }),
          serverIdsByInstanceId: Map<String, String>.unmodifiable(mappings),
        ),
      );
    }

    if (event case _EncryptedPayloadReceived(:final e, :final n)) {
      return RuntimeTransition(
        state,
        effects: [
          _DecodeEncryptedPayload(
            e: e,
            n: n,
            serverIdsByInstanceId: state.serverIdsByInstanceId,
          ),
        ],
      );
    }

    if (event is _NotificationOpenReceived) {
      return RuntimeTransition(state);
    }

    if (event is _ForegroundNotificationDecoded) {
      return RuntimeTransition(state);
    }

    if (event is _PushEffectFailed) {
      final effect = event.effect;
      if (effect is _PushServerEffect) {
        final server = state.servers[effect.serverId];
        if (server == null) return RuntimeTransition(state);
        return RuntimeTransition(
          state.copyWith(
            servers: Map<String, PushServerRuntimeState>.unmodifiable({
              ...state.servers,
              effect.serverId: server.copyWith(
                registration: PushServerRegistrationFailed(
                  event.error,
                  deviceToken: _deviceToken(server.registration),
                ),
              ),
            }),
          ),
        );
      }
      if (effect is _WireHandlers) {
        return RuntimeTransition(
          state.copyWith(handlers: const PushHandlersReady()),
        );
      }
      return RuntimeTransition(state);
    }

    return RuntimeTransition(state);
  }

  Future<_PushEvent?> _execute(
    _PushEffect effect,
    RuntimeEffectContext context,
  ) async {
    switch (effect) {
      case _WireHandlers():
        service.onEncryptedPayload((e, n) {
          _machine.dispatch(_EncryptedPayloadReceived(e, n));
        });
        service.onNotificationOpen(({session, instanceId, viewId}) {
          _machine.dispatch(
            _NotificationOpenReceived(
              session: session,
              instanceId: instanceId,
              viewId: viewId,
            ),
          );
        });
        final pending = await service.takePendingNotificationOpen();
        return _HandlersWired(pending);
      case _RegisterServer(:final serverId):
        final endpoint = _endpoint(serverId);
        if (endpoint == null || !endpoint.isLive || !settings.enabled) {
          return _PushEffectFailed(
            effect: effect,
            error: StateError('push endpoint unavailable'),
            stackTrace: StackTrace.current,
          );
        }
        final registration = await service.register(
          encKeyBase64: settings.encKeyBase64,
        );
        if (!context.isCurrent) return null;
        if (registration == null) {
          throw StateError('platform push registration unavailable');
        }
        final instanceId = await endpoint.device.register(
          deviceToken: registration.deviceToken,
          platform: registration.platform,
          encKeyBase64: registration.encKeyBase64,
          environment: registration.environment,
          appVersion: registration.appVersion,
          mutedSessions: settings.mutedSessions.toList(),
        );
        if (!context.isCurrent) return null;
        if (instanceId != null && instanceId.isNotEmpty) {
          await settings.bindInstanceToServer(instanceId, serverId);
          if (!context.isCurrent) return null;
        }
        return _ServerRegistered(
          serverId: serverId,
          deviceToken: registration.deviceToken,
          instanceId: instanceId,
        );
      case _UnregisterServer(:final serverId, :final deviceToken):
        final endpoint = _endpoint(serverId);
        if (endpoint != null && endpoint.isLive && deviceToken.isNotEmpty) {
          await endpoint.device.unregister(deviceToken);
        }
        if (!context.isCurrent) return null;
        return _ServerUnregistered(serverId);
      case _CancelServerWork():
        return null;
      case _UnregisterPlatform():
        await service.unregister();
        return null;
      case _DecodeEncryptedPayload(
        :final e,
        :final n,
        :final serverIdsByInstanceId,
      ):
        final plain = await decryptPushPayload(
          encKeyB64: settings.encKeyBase64,
          eB64: e,
          nB64: n,
        );
        if (plain == null) return null;
        final obj = jsonDecode(plain) as Map<String, Object?>;
        final motif = (obj['motif'] as Map).cast<String, Object?>();
        final instanceId = motif['instance_id'] as String;
        final sessionId = motif['session_id'] as String?;
        final viewId = motif['view_id'] as String?;
        if (settings.isMuted(sessionId ?? '')) return null;
        final serverId = serverIdsByInstanceId[instanceId];
        if (serverId == null) return null;
        return _ForegroundNotificationDecoded(
          serverId: serverId,
          notification: MotifNotification(
            title: (obj['title'] as String?) ?? 'Motif',
            body: (obj['body'] as String?) ?? '',
            sessionId: sessionId,
            viewId: viewId,
            kind: motif['kind'] as String,
          ),
        );
    }
  }

  void _onTransition(
    RuntimeTransitionRecord<PushRuntimeState, _PushEvent> transition,
  ) {
    settings.viewModel.runtime = transition.current;
    switch (transition.event) {
      case _ForegroundNotificationDecoded(:final serverId, :final notification):
        showNotification(serverId, notification);
      case _NotificationOpenReceived(
        :final session,
        :final instanceId,
        :final viewId,
      ):
        _openSessionFromNotification(
          session: session,
          instanceId: instanceId,
          viewId: viewId,
          serverIdsByInstanceId: transition.current.serverIdsByInstanceId,
        );
      case _HandlersWired(:final pendingOpen) when pendingOpen != null:
        _openSessionFromNotification(
          session: pendingOpen.session,
          instanceId: pendingOpen.instanceId,
          viewId: pendingOpen.viewId,
          serverIdsByInstanceId: transition.current.serverIdsByInstanceId,
        );
      default:
        break;
    }
    _settleRegistrationWaiters(transition.current);
  }

  PushServerEndpoint? _endpoint(String serverId) => serverEndpoints()
      .where((candidate) => candidate.serverId == serverId)
      .firstOrNull;

  void _openSessionFromNotification({
    required String? session,
    required String? instanceId,
    required String? viewId,
    required Map<String, String> serverIdsByInstanceId,
  }) {
    final sessionId = session?.trim();
    if (sessionId == null ||
        sessionId.isEmpty ||
        instanceId == null ||
        instanceId.isEmpty ||
        settings.isMuted(sessionId)) {
      return;
    }
    var serverId = serverIdsByInstanceId[instanceId];
    final persisted = settings.serverIdForInstance(instanceId);
    if (serverId == null && persisted != null && serverExists(persisted)) {
      serverId = persisted;
    }
    if (serverId == null || serverId.isEmpty) return;
    requestOpenSession(serverId: serverId, session: sessionId, viewId: viewId);
  }

  String? _deviceToken(PushServerRegistrationState registration) =>
      switch (registration) {
        PushServerRegistered(:final deviceToken) => deviceToken,
        PushServerUnregistering(:final deviceToken) => deviceToken,
        PushServerRegistering(:final previousDeviceToken) =>
          previousDeviceToken,
        PushServerRegistrationFailed(:final deviceToken) => deviceToken,
        _ => null,
      };

  PushServerRegistrationState _registrationBeforeRetry(
    PushRuntimeState state,
    String serverId,
    PushServerRegistering registering,
  ) {
    final token = registering.previousDeviceToken;
    if (token == null || token.isEmpty) return const PushServerIdle();
    String? instanceId;
    for (final entry in state.serverIdsByInstanceId.entries) {
      if (entry.value == serverId) {
        instanceId = entry.key;
        break;
      }
    }
    return PushServerRegistered(deviceToken: token, instanceId: instanceId);
  }

  void _settleRegistrationWaiters(PushRuntimeState state) {
    for (final entry in _registrationWaiters.entries.toList()) {
      final registration = state.servers[entry.key]?.registration;
      if (registration is PushServerRegistering) continue;
      _registrationWaiters.remove(entry.key);
      for (final waiter in entry.value) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }

  void dispose() {
    _machine.dispose();
    for (final waiters in _registrationWaiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
    _registrationWaiters.clear();
  }
}
