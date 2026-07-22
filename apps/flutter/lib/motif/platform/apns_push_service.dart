import 'dart:io';

import 'package:flutter/foundation.dart';
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
  Future<String?>? _tokenRequest;
  String? _cachedToken;
  void Function(String e, String n)? _encryptedHandler;
  void Function({required String? session, String? instanceId, String? viewId})?
  _openHandler;

  @override
  bool get isSupported => Platform.isIOS || Platform.isMacOS;

  @override
  Future<PushRegistration?> register({required String encKeyBase64}) async {
    if (!isSupported) return null;
    final token = _cachedToken ?? await _requestToken();
    if (token == null || token.isEmpty) return null;
    // Mirror the key into the App Group container for the NSE (iOS background
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
      environment: kReleaseMode ? 'production' : 'sandbox',
    );
  }

  Future<String?> _requestToken() {
    final existing = _tokenRequest;
    if (existing != null) return existing;
    final request = _requestTokenImpl();
    _tokenRequest = request;
    return request.whenComplete(() => _tokenRequest = null);
  }

  Future<String?> _requestTokenImpl() async {
    try {
      final granted =
          await _ch.invokeMethod<bool>('requestAuthorization') ?? false;
      if (!granted) return null;
      final token = await _ch.invokeMethod<String>(
        'registerForRemoteNotifications',
      );
      if (token == null || token.isEmpty) return null;
      _cachedToken = token;
      return token;
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

  void _ensureChannelHandler() {
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPush':
          final args = (call.arguments as Map).cast<String, Object?>();
          final e = args['e'] as String?;
          final n = args['n'] as String?;
          if (e != null && n != null) _encryptedHandler?.call(e, n);
        case 'onNotificationOpen':
          final args = (call.arguments as Map).cast<String, Object?>();
          _openHandler?.call(
            session: args['session'] as String?,
            instanceId: args['instance_id'] as String?,
            viewId: args['view_id'] as String?,
          );
      }
      return null;
    });
  }

  @override
  void onEncryptedPayload(void Function(String e, String n) handler) {
    _encryptedHandler = handler;
    _ensureChannelHandler();
  }

  @override
  void onNotificationOpen(
    void Function({
      required String? session,
      String? instanceId,
      String? viewId,
    })
    handler,
  ) {
    _openHandler = handler;
    _ensureChannelHandler();
  }

  @override
  Future<({String? session, String? instanceId, String? viewId})?>
  takePendingNotificationOpen() async {
    if (!isSupported) return null;
    try {
      final raw = await _ch.invokeMethod<Object?>(
        'takePendingNotificationOpen',
      );
      if (raw is! Map) return null;
      final args = raw.cast<String, Object?>();
      final session = args['session'] as String?;
      final instanceId = args['instance_id'] as String?;
      final viewId = args['view_id'] as String?;
      if ((session == null || session.isEmpty) &&
          (instanceId == null || instanceId.isEmpty) &&
          (viewId == null || viewId.isEmpty)) {
        return null;
      }
      return (session: session, instanceId: instanceId, viewId: viewId);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
