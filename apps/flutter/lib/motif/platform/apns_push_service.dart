import 'dart:io';

import 'package:flutter/services.dart';

import 'services.dart';

/// E2E push via **native APNs** (no Firebase). Talks to the host AppDelegate
/// over a MethodChannel: requests notification authorization, registers for
/// remote notifications, and returns the APNs device token. The per-device
/// AES-256-GCM key (from `PushSettingsStore`) is sent to `motifd` via
/// `device.register`; motifd encrypts payloads with it and the iOS Notification
/// Service Extension decrypts on-device (see `push_crypto.dart` for the scheme).
///
/// Supported on iOS/macOS (APNs). Other platforms get a no-op.
class ApnsPushService implements PushService {
  static const _ch = MethodChannel('motif/push');

  @override
  bool get isSupported => Platform.isIOS || Platform.isMacOS;

  @override
  Future<PushRegistration?> register({required String encKeyBase64}) async {
    if (!isSupported) return null;
    try {
      final granted =
          await _ch.invokeMethod<bool>('requestAuthorization') ?? false;
      if (!granted) return null;
      final token = await _ch.invokeMethod<String>(
        'registerForRemoteNotifications',
      );
      if (token == null || token.isEmpty) return null;
      // Mirror the key into the App Group keychain for the NSE (iOS background
      // decrypt). Best-effort; foreground decrypt works regardless.
      if (Platform.isIOS) {
        try {
          await _ch.invokeMethod('storeEncKey', {'key': encKeyBase64});
        } catch (_) {}
      }
      return PushRegistration(
        deviceToken: token,
        platform: Platform.isIOS ? 'ios' : 'macos',
        encKeyBase64: encKeyBase64,
      );
    } on MissingPluginException {
      // Native side not wired (e.g. running under flutter test) — treat as
      // unavailable rather than crashing.
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> unregister() async {
    try {
      await _ch.invokeMethod('unregister');
    } catch (_) {}
  }

  @override
  void onEncryptedPayload(void Function(String e, String n) handler) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onPush') {
        final args = (call.arguments as Map).cast<String, Object?>();
        final e = args['e'] as String?;
        final n = args['n'] as String?;
        if (e != null && n != null) handler(e, n);
      }
      return null;
    });
  }
}
