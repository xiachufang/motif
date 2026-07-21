import 'dart:async';

import 'package:flutter_observation/flutter_observation.dart';

import '../runtime/runtime_effect.dart';
import '../runtime/runtime_machine.dart';
import 'device_registration_view_model.dart';
import 'device_runtime_state.dart';

typedef DeviceRpcCall =
    Future<Map<String, Object?>> Function(
      String method, [
      Map<String, Object?> params,
    ]);

final class DeviceTransport {
  const DeviceTransport({required this.isAvailable, required this.call});

  final bool Function() isAvailable;
  final DeviceRpcCall call;
}

final class _DeviceRegistrationPayload {
  const _DeviceRegistrationPayload({
    required this.deviceToken,
    required this.platform,
    required this.encKeyBase64,
    required this.environment,
    required this.appVersion,
    required this.mutedSessions,
  });

  final String deviceToken;
  final String platform;
  final String encKeyBase64;
  final String? environment;
  final String? appVersion;
  final List<String> mutedSessions;
}

sealed class _DeviceEvent {
  const _DeviceEvent();
}

final class _RegisterRequested extends _DeviceEvent {
  const _RegisterRequested({required this.operationId, required this.payload});

  final int operationId;
  final _DeviceRegistrationPayload payload;
}

final class _UnregisterRequested extends _DeviceEvent {
  const _UnregisterRequested({
    required this.operationId,
    required this.deviceToken,
  });

  final int operationId;
  final String deviceToken;
}

final class _MuteRequested extends _DeviceEvent {
  const _MuteRequested({
    required this.operationId,
    required this.deviceToken,
    required this.session,
    required this.muted,
  });

  final int operationId;
  final String deviceToken;
  final String session;
  final bool muted;
}

final class _RegistrationCompleted extends _DeviceEvent {
  const _RegistrationCompleted({
    required this.operationId,
    required this.instanceId,
  });

  final int operationId;
  final String? instanceId;
}

final class _UnregisterCompleted extends _DeviceEvent {
  const _UnregisterCompleted(this.operationId);

  final int operationId;
}

final class _MuteCompleted extends _DeviceEvent {
  const _MuteCompleted({required this.operationId, required this.session});

  final int operationId;
  final String session;
}

final class _DeviceEffectFailed extends _DeviceEvent {
  const _DeviceEffectFailed({
    required this.effect,
    required this.error,
    required this.stackTrace,
  });

  final _DeviceEffect effect;
  final Object error;
  final StackTrace stackTrace;
}

sealed class _DeviceEffect implements RuntimeEffect {
  const _DeviceEffect({required this.operationId});

  final int operationId;
}

sealed class _DeviceRegistrationEffect extends _DeviceEffect {
  const _DeviceRegistrationEffect({required super.operationId});

  @override
  Object get key => 'device-registration';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.restartable;
}

final class _RegisterDevice extends _DeviceRegistrationEffect {
  const _RegisterDevice({required super.operationId, required this.payload});

  final _DeviceRegistrationPayload payload;
}

final class _UnregisterDevice extends _DeviceRegistrationEffect {
  const _UnregisterDevice({
    required super.operationId,
    required this.deviceToken,
  });

  final String deviceToken;
}

final class _SetSessionMuted extends _DeviceEffect {
  const _SetSessionMuted({
    required super.operationId,
    required this.deviceToken,
    required this.session,
    required this.muted,
  });

  final String deviceToken;
  final String session;
  final bool muted;

  @override
  Object get key => 'device-mute:$session';

  @override
  RuntimeEffectMode get mode => RuntimeEffectMode.serial;
}

enum _DeviceWaiterKind { registration, mute }

final class _DeviceWaiter {
  const _DeviceWaiter({required this.kind, required this.completer});

  final _DeviceWaiterKind kind;
  final Completer<Object?> completer;
}

/// Server-scoped device registration state machine.
final class DeviceController {
  DeviceController({required this.viewModel, required this.transport}) {
    _machine = RuntimeMachine<DeviceRuntimeState, _DeviceEvent, _DeviceEffect>(
      initialState: const DeviceRuntimeState.initial(),
      reducer: _reduce,
      execute: _execute,
      mapEffectError: (effect, error, stackTrace) => _DeviceEffectFailed(
        effect: effect,
        error: error,
        stackTrace: stackTrace,
      ),
      onTransition: _onTransition,
    );
    _project(_machine.state);
  }

  final DeviceRegistrationViewModel viewModel;
  final DeviceTransport transport;
  late final RuntimeMachine<DeviceRuntimeState, _DeviceEvent, _DeviceEffect>
  _machine;
  final Map<int, _DeviceWaiter> _waiters = {};

  DeviceRuntimeState get runtimeState => _machine.state;

  Future<String?> register({
    required String deviceToken,
    required String platform,
    required String encKeyBase64,
    String? environment,
    String? appVersion,
    List<String> mutedSessions = const [],
  }) async {
    if (!transport.isAvailable()) return null;
    final operationId = runtimeState.operationSequence + 1;
    final completer = Completer<Object?>();
    _waiters[operationId] = _DeviceWaiter(
      kind: _DeviceWaiterKind.registration,
      completer: completer,
    );
    _machine.dispatch(
      _RegisterRequested(
        operationId: operationId,
        payload: _DeviceRegistrationPayload(
          deviceToken: deviceToken,
          platform: platform,
          encKeyBase64: encKeyBase64,
          environment: environment,
          appVersion: appVersion,
          mutedSessions: List<String>.unmodifiable(mutedSessions),
        ),
      ),
    );
    return await completer.future as String?;
  }

  Future<void> unregister(String deviceToken) async {
    if (!transport.isAvailable()) return;
    final operationId = runtimeState.operationSequence + 1;
    final completer = Completer<Object?>();
    _waiters[operationId] = _DeviceWaiter(
      kind: _DeviceWaiterKind.registration,
      completer: completer,
    );
    _machine.dispatch(
      _UnregisterRequested(operationId: operationId, deviceToken: deviceToken),
    );
    await completer.future;
  }

  Future<void> setSessionMuted({
    required String deviceToken,
    required String session,
    required bool muted,
  }) async {
    if (!transport.isAvailable()) return;
    final operationId = runtimeState.operationSequence + 1;
    final completer = Completer<Object?>();
    _waiters[operationId] = _DeviceWaiter(
      kind: _DeviceWaiterKind.mute,
      completer: completer,
    );
    _machine.dispatch(
      _MuteRequested(
        operationId: operationId,
        deviceToken: deviceToken,
        session: session,
        muted: muted,
      ),
    );
    await completer.future;
  }

  RuntimeTransition<DeviceRuntimeState, _DeviceEffect> _reduce(
    DeviceRuntimeState state,
    _DeviceEvent event,
  ) {
    if (event case _RegisterRequested(:final operationId, :final payload)) {
      return RuntimeTransition(
        state.copyWith(
          generation: state.generation + 1,
          operationSequence: operationId,
          registration: DeviceRegistrationRegistering(operationId),
        ),
        effects: [_RegisterDevice(operationId: operationId, payload: payload)],
      );
    }
    if (event case _UnregisterRequested(
      :final operationId,
      :final deviceToken,
    )) {
      return RuntimeTransition(
        state.copyWith(
          generation: state.generation + 1,
          operationSequence: operationId,
          registration: DeviceRegistrationUnregistering(operationId),
        ),
        effects: [
          _UnregisterDevice(operationId: operationId, deviceToken: deviceToken),
        ],
      );
    }
    if (event case _MuteRequested(
      :final operationId,
      :final deviceToken,
      :final session,
      :final muted,
    )) {
      return RuntimeTransition(
        state.copyWith(
          operationSequence: operationId,
          muteOperationIds: Map<String, int>.unmodifiable({
            ...state.muteOperationIds,
            session: operationId,
          }),
        ),
        effects: [
          _SetSessionMuted(
            operationId: operationId,
            deviceToken: deviceToken,
            session: session,
            muted: muted,
          ),
        ],
      );
    }
    if (event case _RegistrationCompleted(
      :final operationId,
      :final instanceId,
    )) {
      if (state.registration case DeviceRegistrationRegistering(
        operationId: final activeId,
      ) when activeId == operationId) {
        return RuntimeTransition(
          state.copyWith(
            registration: DeviceRegistrationRegistered(instanceId),
          ),
        );
      }
      return RuntimeTransition(state);
    }
    if (event case _UnregisterCompleted(:final operationId)) {
      if (state.registration case DeviceRegistrationUnregistering(
        operationId: final activeId,
      ) when activeId == operationId) {
        return RuntimeTransition(
          state.copyWith(registration: const DeviceRegistrationIdle()),
        );
      }
      return RuntimeTransition(state);
    }
    if (event case _MuteCompleted(:final operationId, :final session)) {
      if (state.muteOperationIds[session] != operationId) {
        return RuntimeTransition(state);
      }
      return RuntimeTransition(
        state.copyWith(
          muteOperationIds: Map<String, int>.unmodifiable(
            Map<String, int>.from(state.muteOperationIds)..remove(session),
          ),
        ),
      );
    }
    if (event is _DeviceEffectFailed) {
      final effect = event.effect;
      if (effect is _SetSessionMuted) {
        if (state.muteOperationIds[effect.session] != effect.operationId) {
          return RuntimeTransition(state);
        }
        return RuntimeTransition(
          state.copyWith(
            muteOperationIds: Map<String, int>.unmodifiable(
              Map<String, int>.from(state.muteOperationIds)
                ..remove(effect.session),
            ),
          ),
        );
      }
      final activeOperationId = switch (state.registration) {
        DeviceRegistrationRegistering(:final operationId) => operationId,
        DeviceRegistrationUnregistering(:final operationId) => operationId,
        _ => null,
      };
      if (activeOperationId != effect.operationId) {
        return RuntimeTransition(state);
      }
      return RuntimeTransition(
        state.copyWith(
          registration: DeviceRegistrationFailed(
            operationId: effect.operationId,
            error: event.error,
            stackTrace: event.stackTrace,
          ),
        ),
      );
    }
    return RuntimeTransition(state);
  }

  Future<_DeviceEvent?> _execute(
    _DeviceEffect effect,
    RuntimeEffectContext context,
  ) async {
    switch (effect) {
      case _RegisterDevice(:final operationId, :final payload):
        final body = await transport.call('device.register', {
          'device_token': payload.deviceToken,
          'platform': payload.platform,
          'environment': ?payload.environment,
          'enc_key': payload.encKeyBase64,
          'app_version': ?payload.appVersion,
          'muted_sessions': payload.mutedSessions,
        });
        if (!context.isCurrent) return null;
        return _RegistrationCompleted(
          operationId: operationId,
          instanceId: body['instance_id'] as String?,
        );
      case _UnregisterDevice(:final operationId, :final deviceToken):
        await transport.call('device.unregister', {
          'device_token': deviceToken,
        });
        if (!context.isCurrent) return null;
        return _UnregisterCompleted(operationId);
      case _SetSessionMuted(
        :final operationId,
        :final deviceToken,
        :final session,
        :final muted,
      ):
        await transport.call('device.set_session_muted', {
          'device_token': deviceToken,
          'session': session,
          'muted': muted,
        });
        return _MuteCompleted(operationId: operationId, session: session);
    }
  }

  void _onTransition(
    RuntimeTransitionRecord<DeviceRuntimeState, _DeviceEvent> transition,
  ) {
    _settleWaiters(transition.event, transition.current);
    _project(transition.current);
  }

  void _settleWaiters(_DeviceEvent event, DeviceRuntimeState state) {
    switch (event) {
      case _RegistrationCompleted(:final operationId, :final instanceId):
        _waiters.remove(operationId)?.completer.complete(instanceId);
      case _UnregisterCompleted(:final operationId):
        _waiters.remove(operationId)?.completer.complete();
      case _MuteCompleted(:final operationId):
        _waiters.remove(operationId)?.completer.complete();
      case _DeviceEffectFailed(
        effect: _DeviceEffect(:final operationId),
        :final error,
        :final stackTrace,
      ):
        _waiters
            .remove(operationId)
            ?.completer
            .completeError(error, stackTrace);
      default:
        break;
    }

    final activeRegistrationId = switch (state.registration) {
      DeviceRegistrationRegistering(:final operationId) => operationId,
      DeviceRegistrationUnregistering(:final operationId) => operationId,
      _ => null,
    };
    for (final entry in _waiters.entries.toList()) {
      if (entry.value.kind != _DeviceWaiterKind.registration ||
          entry.key == activeRegistrationId) {
        continue;
      }
      _waiters.remove(entry.key);
      if (!entry.value.completer.isCompleted) {
        entry.value.completer.complete(null);
      }
    }
  }

  void _project(DeviceRuntimeState state) {
    observationTransaction(() {
      viewModel.runtime = state;
      switch (state.registration) {
        case DeviceRegistrationIdle():
          viewModel
            ..phase = DeviceRegistrationPhase.idle
            ..instanceId = null
            ..error = null;
        case DeviceRegistrationRegistering():
          viewModel
            ..phase = DeviceRegistrationPhase.registering
            ..error = null;
        case DeviceRegistrationRegistered(:final instanceId):
          viewModel
            ..phase = DeviceRegistrationPhase.registered
            ..instanceId = instanceId
            ..error = null;
        case DeviceRegistrationUnregistering():
          viewModel
            ..phase = DeviceRegistrationPhase.registering
            ..error = null;
        case DeviceRegistrationFailed(:final error):
          viewModel
            ..phase = DeviceRegistrationPhase.failed
            ..error = '$error';
      }
    });
  }

  void dispose() {
    _machine.dispose();
    for (final waiter in _waiters.values) {
      if (!waiter.completer.isCompleted) waiter.completer.complete(null);
    }
    _waiters.clear();
  }
}
