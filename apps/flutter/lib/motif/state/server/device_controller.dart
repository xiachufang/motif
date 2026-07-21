import 'device_registration_view_model.dart';

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

/// Server-scoped device registration commands and their observable projection.
final class DeviceController {
  DeviceController({required this.viewModel, required this.transport});

  final DeviceRegistrationViewModel viewModel;
  final DeviceTransport transport;

  Future<String?> register({
    required String deviceToken,
    required String platform,
    required String encKeyBase64,
    String? environment,
    String? appVersion,
    List<String> mutedSessions = const [],
  }) async {
    if (!transport.isAvailable()) return null;
    viewModel
      ..phase = DeviceRegistrationPhase.registering
      ..error = null;
    try {
      final body = await transport.call('device.register', {
        'device_token': deviceToken,
        'platform': platform,
        'environment': ?environment,
        'enc_key': encKeyBase64,
        'app_version': ?appVersion,
        'muted_sessions': mutedSessions,
      });
      final instanceId = body['instance_id'] as String?;
      viewModel
        ..instanceId = instanceId
        ..phase = DeviceRegistrationPhase.registered;
      return instanceId;
    } catch (error) {
      viewModel
        ..phase = DeviceRegistrationPhase.failed
        ..error = '$error';
      rethrow;
    }
  }

  Future<void> unregister(String deviceToken) async {
    if (!transport.isAvailable()) return;
    await transport.call('device.unregister', {'device_token': deviceToken});
    viewModel
      ..instanceId = null
      ..phase = DeviceRegistrationPhase.idle
      ..error = null;
  }

  Future<void> setSessionMuted({
    required String deviceToken,
    required String session,
    required bool muted,
  }) async {
    if (!transport.isAvailable()) return;
    await transport.call('device.set_session_muted', {
      'device_token': deviceToken,
      'session': session,
      'muted': muted,
    });
  }
}
