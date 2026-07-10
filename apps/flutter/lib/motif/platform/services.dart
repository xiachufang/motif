/// Platform-capability abstractions for features that need native, per-OS
/// implementations: Tailscale tunneling, speech-to-text, push notifications,
/// and secure secret storage.
///
/// Each is an interface with a safe no-op/default implementation so the app
/// compiles and runs on all six targets today. Real per-platform
/// implementations are introduced behind these interfaces in later phases
/// (MOTIF_FLUTTER_PLAN.md P5/P6) without touching call sites.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/proxy_client.dart';

// ─────────────────────────── Tailscale ───────────────────────────

enum TailscaleStatus { stopped, starting, running, needsAuth, degraded, failed }

class TailscaleState {
  final TailscaleStatus status;
  final String? authUrl;
  final String? detail;
  const TailscaleState(this.status, {this.authUrl, this.detail});
  static const stopped = TailscaleState(TailscaleStatus.stopped);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TailscaleState &&
          status == other.status &&
          authUrl == other.authUrl &&
          detail == other.detail;

  @override
  int get hashCode => Object.hash(status, authUrl, detail);
}

/// A visible tailnet peer that may be a motifd target.
class TailscalePeer {
  final String hostname;
  final String dnsName;
  final String? primaryIP;
  final bool isLikelyMotifd;
  final bool isOnline;

  const TailscalePeer({
    required this.hostname,
    required this.dnsName,
    this.primaryIP,
    required this.isLikelyMotifd,
    required this.isOnline,
  });

  String get id => dnsName.isEmpty ? hostname : dnsName;

  /// Best address to persist in a server config: MagicDNS when present, IP
  /// otherwise.
  String get preferredAddress {
    if (dnsName.isNotEmpty) {
      return dnsName.endsWith('.')
          ? dnsName.substring(0, dnsName.length - 1)
          : dnsName;
    }
    return primaryIP ?? hostname;
  }
}

class TailscalePingResult {
  final bool reachable;
  final String? version;
  final String message;

  const TailscalePingResult._({
    required this.reachable,
    this.version,
    required this.message,
  });

  const TailscalePingResult.reachable(String version)
    : this._(reachable: true, version: version, message: 'Reachable');

  const TailscalePingResult.unreachable(String message)
    : this._(reachable: false, message: message);
}

/// Embeds a tsnet node so the app can reach a tailnet peer directly.
abstract interface class TailscaleService {
  TailscaleState get state;
  Stream<TailscaleState> get states;
  Future<void> start({String? authKey});
  Future<void> stop();

  /// Resolve a MagicDNS name to a reachable address (no-op returns input).
  Future<String> resolveHost(String host);

  /// Enumerate visible tailnet peers from the embedded Tailscale node.
  Future<List<TailscalePeer>> discoverPeers();

  /// Probe a motifd `/ping` endpoint through the embedded Tailscale node.
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  });

  /// The local tsnet loopback proxy to route RPC through, or null when not up.
  /// Exposed on the interface so callers needn't depend on the FFI impl (keeps
  /// `dart:ffi` out of the web build — web has no Tailscale).
  ProxySettings? get loopbackProxy => null;
}

/// No-op: the platform has no embedded Tailscale. Direct (non-tailscale)
/// servers still work; tailscale servers are simply unreachable until a real
/// implementation is provided for the platform.
class NoopTailscaleService implements TailscaleService {
  final _controller = StreamController<TailscaleState>.broadcast();
  TailscaleState _state = TailscaleState.stopped;

  @override
  TailscaleState get state => _state;
  @override
  Stream<TailscaleState> get states => _controller.stream;

  void _set(TailscaleState state) {
    _state = state;
    if (!_controller.isClosed) _controller.add(state);
  }

  @override
  Future<void> start({String? authKey}) async {
    _set(
      const TailscaleState(
        TailscaleStatus.failed,
        detail:
            'Embedded Tailscale is unavailable in this build. Bundle libtailscale for this device, or use a direct server.',
      ),
    );
  }

  @override
  Future<void> stop() async => _set(TailscaleState.stopped);
  @override
  Future<String> resolveHost(String host) async => host;
  @override
  Future<List<TailscalePeer>> discoverPeers() async => const [];
  @override
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async => const TailscalePingResult.unreachable('Tailscale off');
  @override
  ProxySettings? get loopbackProxy => null;
}

// ─────────────────────────── speech (ASR) ───────────────────────────

class SpeechPartial {
  final String text;
  const SpeechPartial(this.text);
}

/// Streaming speech-to-text for the "hold to talk" composer button.
abstract interface class SpeechService {
  bool get isAvailable;
  Future<void> start({
    required void Function(String partial) onPartial,
    void Function(double level)? onLevel,
    void Function(Object error)? onError,
  });
  Future<String> stop();
}

class NoopSpeechService implements SpeechService {
  @override
  bool get isAvailable => false;
  @override
  Future<void> start({
    required void Function(String partial) onPartial,
    void Function(double level)? onLevel,
    void Function(Object error)? onError,
  }) async {}
  @override
  Future<String> stop() async => '';
}

// ─────────────────────────── push ───────────────────────────

class PushRegistration {
  final String deviceToken;
  final String platform;
  final String encKeyBase64;
  final String? environment;
  final String? appVersion;

  const PushRegistration({
    required this.deviceToken,
    required this.platform,
    required this.encKeyBase64,
    this.environment,
    this.appVersion,
  });
}

/// Acquires the platform push token (APNs/etc.) and pairs it with the caller's
/// per-device E2E key into a [PushRegistration] for `device.register`. The key
/// is owned by `PushSettingsStore`, so the caller passes it in.
abstract interface class PushService {
  bool get isSupported;
  Future<PushRegistration?> register({required String encKeyBase64});
  Future<void> unregister();

  /// Register a handler for *encrypted* push payloads delivered to the app
  /// while it's running (foreground). The handler receives the raw `(e, n)`
  /// wire fields; the caller decrypts with the per-device key. (Background/
  /// killed delivery is decrypted by the Notification Service Extension.)
  void onEncryptedPayload(void Function(String e, String n) handler);

  /// User tapped a system notification (background / cold start). [session]
  /// and optional [instanceId] come from the NSE-decrypted `userInfo`.
  void onNotificationOpen(
    void Function({required String? session, String? instanceId}) handler,
  );

  /// Drain a cold-start tap that arrived before Dart registered handlers.
  /// Returns `null` when none is pending.
  Future<({String? session, String? instanceId})?> takePendingNotificationOpen();
}

class NoopPushService implements PushService {
  @override
  bool get isSupported => false;
  @override
  Future<PushRegistration?> register({required String encKeyBase64}) async =>
      null;
  @override
  Future<void> unregister() async {}
  @override
  void onEncryptedPayload(void Function(String e, String n) handler) {}
  @override
  void onNotificationOpen(
    void Function({required String? session, String? instanceId}) handler,
  ) {}
  @override
  Future<({String? session, String? instanceId})?>
  takePendingNotificationOpen() async => null;
}

// ─────────────────────────── bundle of services ───────────────────────────

/// The set of platform services available to the app. Defaults to no-ops so the
/// app runs everywhere; concrete platforms swap in real implementations.
@immutable
class PlatformServices {
  final TailscaleService tailscale;
  final SpeechService speech;
  final PushService push;

  const PlatformServices({
    required this.tailscale,
    required this.speech,
    required this.push,
  });

  factory PlatformServices.defaults() => PlatformServices(
    tailscale: NoopTailscaleService(),
    speech: NoopSpeechService(),
    push: NoopPushService(),
  );
}
