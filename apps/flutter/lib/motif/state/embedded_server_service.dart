/// Public embedded-server surface used by the shared app. The default
/// implementation is a pure-Dart no-op so web/mobile builds do not compile the
/// desktop-only motif-embed FFI library at all. Desktop entrypoints can inject a
/// real implementation with [EmbeddedServerFactory].
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stable id of the auto-managed loopback server entry.
const String kEmbeddedServerId = 'embedded-local';

/// Default public push relay for embedded motifd. The Rust embed layer accepts
/// this bare host and expands it to `https://<host>/v1/push`.
const String kDefaultPushRelayAddress = 'motif-push-relay.slothease.com';

typedef EmbeddedServerFactory =
    Future<EmbeddedServerService> Function(SharedPreferences prefs);

Future<EmbeddedServerService> createNoopEmbeddedServerService(
  SharedPreferences prefs,
) async => NoopEmbeddedServerService();

/// How the embedded server should listen. Mirrors the Rust `ListenMode`
/// (serialized lowercase) in the desktop implementation.
enum EmbeddedListenMode { loopback, lan, off }

@immutable
class EmbeddedServerConfig {
  final EmbeddedListenMode listenMode;
  final int port;
  final bool tsEnabled;
  final String tsHostname;
  final String tsAuthkey;
  final String tsControlUrl;
  final bool rzvEnabled;
  final String rzvRelay;
  final String pushRelayUrl;
  final bool autostart;

  const EmbeddedServerConfig({
    this.listenMode = EmbeddedListenMode.loopback,
    this.port = 7777,
    this.tsEnabled = false,
    this.tsHostname = '',
    this.tsAuthkey = '',
    this.tsControlUrl = '',
    this.rzvEnabled = false,
    this.rzvRelay = '',
    this.pushRelayUrl = kDefaultPushRelayAddress,
    this.autostart = false,
  });

  EmbeddedServerConfig copyWith({
    EmbeddedListenMode? listenMode,
    int? port,
    bool? tsEnabled,
    String? tsHostname,
    String? tsAuthkey,
    String? tsControlUrl,
    bool? rzvEnabled,
    String? rzvRelay,
    String? pushRelayUrl,
    bool? autostart,
  }) => EmbeddedServerConfig(
    listenMode: listenMode ?? this.listenMode,
    port: port ?? this.port,
    tsEnabled: tsEnabled ?? this.tsEnabled,
    tsHostname: tsHostname ?? this.tsHostname,
    tsControlUrl: tsControlUrl ?? this.tsControlUrl,
    tsAuthkey: tsAuthkey ?? this.tsAuthkey,
    rzvEnabled: rzvEnabled ?? this.rzvEnabled,
    rzvRelay: rzvRelay ?? this.rzvRelay,
    pushRelayUrl: pushRelayUrl ?? this.pushRelayUrl,
    autostart: autostart ?? this.autostart,
  );
}

enum EmbeddedRunState { stopped, starting, running, failed }

@immutable
class EmbeddedServerStatus {
  final bool running;
  final bool starting;
  final List<String> boundAddrs;
  final int sessionCount;
  final String? tailscaleState;
  final String? authUrl;
  final String? pairingUri;
  final String? error;

  const EmbeddedServerStatus({
    this.running = false,
    this.starting = false,
    this.boundAddrs = const [],
    this.sessionCount = 0,
    this.tailscaleState,
    this.authUrl,
    this.pairingUri,
    this.error,
  });

  EmbeddedRunState get phase {
    if (running) return EmbeddedRunState.running;
    if (starting) return EmbeddedRunState.starting;
    if (error != null) return EmbeddedRunState.failed;
    return EmbeddedRunState.stopped;
  }

  /// The loopback `host:port` a local client can reach. Desktop implementations
  /// derive it from bound TCP addresses; no-op implementations return null.
  ({String host, int port})? get loopbackEndpoint {
    for (final a in boundAddrs) {
      final hp = a.startsWith('tcp://') ? a.substring(6) : null;
      if (hp == null) continue;
      final i = hp.lastIndexOf(':');
      if (i <= 0) continue;
      final port = int.tryParse(hp.substring(i + 1));
      if (port == null) continue;
      return (host: '127.0.0.1', port: port);
    }
    return null;
  }
}

abstract class EmbeddedServerService extends ChangeNotifier {
  bool get available;
  EmbeddedServerConfig get config;
  EmbeddedServerStatus get status;
  EmbeddedRunState get phase => status.phase;

  Future<void> updateConfig(EmbeddedServerConfig next);
  String generateToken();
  Future<void> start();
  Future<void> stop();
  List<String> tailLogs([int n = 200]);
}

class NoopEmbeddedServerService extends EmbeddedServerService {
  @override
  bool get available => false;

  @override
  EmbeddedServerConfig get config => const EmbeddedServerConfig();

  @override
  EmbeddedServerStatus get status => const EmbeddedServerStatus();

  @override
  Future<void> updateConfig(EmbeddedServerConfig next) async {}

  @override
  String generateToken() => '';

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  List<String> tailLogs([int n = 200]) => const [];
}
