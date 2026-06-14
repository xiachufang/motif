/// Desktop-only owner of the *embedded* motifd server. The app can run a
/// server in-process (over the `motif-embed` cdylib) and control it from the
/// tray — the Flutter equivalent of the Tauri menu-bar app. This service holds
/// the persisted config, drives start/stop, polls status, and surfaces the
/// running server as a connectable [MotifServer] so the existing connection
/// flow can attach to it over loopback.
///
/// On platforms where the native library isn't bundled (web, mobile), or if it
/// fails to load, [available] is false and every operation is a no-op.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';
import '../platform/motif_embed_ffi.dart';
import 'stores.dart';

/// Stable id of the auto-managed loopback server entry.
const String kEmbeddedServerId = 'embedded-local';

const String _kConfigKey = 'motif.embedded.v1';

bool get _isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

/// How the embedded server should listen. Mirrors the Rust `ListenMode`
/// (serialized lowercase).
enum EmbeddedListenMode {
  loopback,
  lan,
  off;

  static EmbeddedListenMode fromWire(Object? v) => switch (v) {
    'lan' => EmbeddedListenMode.lan,
    'off' => EmbeddedListenMode.off,
    _ => EmbeddedListenMode.loopback,
  };
}

/// Embedded-server settings. JSON shape mirrors the Rust `MenuConfig`
/// field-for-field (snake_case) — it is passed verbatim into
/// `motif_embed_start`.
@immutable
class EmbeddedServerConfig {
  final EmbeddedListenMode listenMode;
  final int port;
  final bool tsEnabled;
  final String tsHostname;
  final String tsAuthkey;
  final String tsControlUrl;
  final bool authEnabled;
  final String authToken;
  final bool rzvEnabled;
  final String rzvRelay;
  final bool autostart;

  const EmbeddedServerConfig({
    this.listenMode = EmbeddedListenMode.loopback,
    this.port = 7777,
    this.tsEnabled = false,
    this.tsHostname = '',
    this.tsAuthkey = '',
    this.tsControlUrl = '',
    this.authEnabled = false,
    this.authToken = '',
    this.rzvEnabled = false,
    this.rzvRelay = '',
    this.autostart = false,
  });

  EmbeddedServerConfig copyWith({
    EmbeddedListenMode? listenMode,
    int? port,
    bool? tsEnabled,
    String? tsHostname,
    String? tsAuthkey,
    String? tsControlUrl,
    bool? authEnabled,
    String? authToken,
    bool? rzvEnabled,
    String? rzvRelay,
    bool? autostart,
  }) => EmbeddedServerConfig(
    listenMode: listenMode ?? this.listenMode,
    port: port ?? this.port,
    tsEnabled: tsEnabled ?? this.tsEnabled,
    tsHostname: tsHostname ?? this.tsHostname,
    tsAuthkey: tsAuthkey ?? this.tsAuthkey,
    tsControlUrl: tsControlUrl ?? this.tsControlUrl,
    authEnabled: authEnabled ?? this.authEnabled,
    authToken: authToken ?? this.authToken,
    rzvEnabled: rzvEnabled ?? this.rzvEnabled,
    rzvRelay: rzvRelay ?? this.rzvRelay,
    autostart: autostart ?? this.autostart,
  );

  Map<String, Object?> toJson() => {
    'listen_mode': listenMode.name,
    'port': port,
    'tailscale': {
      'enabled': tsEnabled,
      'hostname': tsHostname,
      'authkey': tsAuthkey,
      'control_url': tsControlUrl,
    },
    'auth': {'enabled': authEnabled, 'token': authToken},
    'rzv': {'enabled': rzvEnabled, 'relay': rzvRelay},
    'autostart': autostart,
  };

  factory EmbeddedServerConfig.fromJson(Map<String, Object?> j) {
    final ts = (j['tailscale'] as Map?)?.cast<String, Object?>() ?? const {};
    final auth = (j['auth'] as Map?)?.cast<String, Object?>() ?? const {};
    final rzv = (j['rzv'] as Map?)?.cast<String, Object?>() ?? const {};
    return EmbeddedServerConfig(
      listenMode: EmbeddedListenMode.fromWire(j['listen_mode']),
      port: (j['port'] as num?)?.toInt() ?? 7777,
      tsEnabled: ts['enabled'] == true,
      tsHostname: (ts['hostname'] as String?) ?? '',
      tsAuthkey: (ts['authkey'] as String?) ?? '',
      tsControlUrl: (ts['control_url'] as String?) ?? '',
      authEnabled: auth['enabled'] == true,
      authToken: (auth['token'] as String?) ?? '',
      rzvEnabled: rzv['enabled'] == true,
      rzvRelay: (rzv['relay'] as String?) ?? '',
      autostart: j['autostart'] == true,
    );
  }
}

/// Run phase the UI/tray reflect.
enum EmbeddedRunState { stopped, starting, running, failed }

/// Decoded snapshot of the embedded server (mirrors the Rust `StatusDto`).
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

  /// The loopback `host:port` a local client can reach, derived from a
  /// `tcp://…` bound address (LAN's `0.0.0.0` is reachable via `127.0.0.1`).
  /// Null when the server only listens on Tailscale.
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

  factory EmbeddedServerStatus.fromJson(Map<String, Object?> j) {
    final ts = (j['tailscale'] as Map?)?.cast<String, Object?>();
    return EmbeddedServerStatus(
      running: j['running'] == true,
      starting: j['starting'] == true,
      boundAddrs:
          (j['bound_addrs'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      sessionCount: (j['session_count'] as num?)?.toInt() ?? 0,
      tailscaleState: ts?['backend_state'] as String?,
      authUrl: j['auth_url'] as String?,
      pairingUri: j['pairing_uri'] as String?,
      error: j['error'] as String?,
    );
  }
}

class EmbeddedServerService extends ChangeNotifier {
  final SharedPreferences _prefs;
  final ServerStore _servers;
  final LibMotifEmbed? _lib;

  EmbeddedServerConfig _config = const EmbeddedServerConfig();
  EmbeddedServerStatus _status = const EmbeddedServerStatus();
  Timer? _poll;

  EmbeddedServerService._(this._prefs, this._servers, this._lib) {
    final raw = _prefs.getString(_kConfigKey);
    if (raw != null) {
      final map = jsonDecodeMap(raw);
      if (map != null) _config = EmbeddedServerConfig.fromJson(map);
    }
  }

  /// Build the service, loading the native library and initializing logging on
  /// desktop. Best-effort autostart if the saved config asks for it.
  static Future<EmbeddedServerService> create(
    SharedPreferences prefs,
    ServerStore servers,
  ) async {
    LibMotifEmbed? lib;
    if (_isDesktop) {
      lib = LibMotifEmbed.tryOpenDefault();
      if (lib != null) {
        try {
          final support = await getApplicationSupportDirectory();
          lib.init('${support.path}/motif/logs');
        } catch (_) {
          // Logging init is best-effort; the server still runs without it.
        }
      }
    }
    final svc = EmbeddedServerService._(prefs, servers, lib);
    if (svc.available && svc._config.autostart) {
      unawaited(svc.start());
    }
    return svc;
  }

  /// Whether the embedded-server capability is present (desktop + library
  /// loaded). When false, the tray/settings hide the feature.
  bool get available => _lib != null;

  EmbeddedServerConfig get config => _config;
  EmbeddedServerStatus get status => _status;
  EmbeddedRunState get phase => _status.phase;

  Future<void> updateConfig(EmbeddedServerConfig next) async {
    _config = next;
    await _prefs.setString(_kConfigKey, jsonEncodeMap(next.toJson()));
    notifyListeners();
  }

  /// Generate a fresh bearer token via the native RNG (empty if unavailable).
  String generateToken() => _lib?.generateToken() ?? '';

  /// Start the embedded server with the current config. Non-blocking; status
  /// is reflected through [status] as the poller advances.
  Future<void> start() async {
    final lib = _lib;
    if (lib == null) return;
    lib.start(jsonEncode(_config.toJson()));
    _startPolling();
    await _refresh();
  }

  /// Stop the embedded server. Idempotent.
  Future<void> stop() async {
    final lib = _lib;
    if (lib == null) return;
    lib.stop();
    await _refresh();
    if (!_status.starting && !_status.running) _stopPolling();
  }

  /// Last [n] log lines from the native ring (empty list if unavailable).
  List<String> tailLogs([int n = 200]) {
    final lib = _lib;
    if (lib == null) return const [];
    try {
      final raw = jsonDecode(lib.tailLogs(n));
      if (raw is List) return raw.map((e) => e.toString()).toList();
    } catch (_) {}
    return const [];
  }

  void _startPolling() {
    _poll ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refresh()),
    );
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  String _lastRaw = '';

  Future<void> _refresh() async {
    final lib = _lib;
    if (lib == null) return;
    final String raw;
    try {
      raw = lib.statusJson();
    } catch (_) {
      return;
    }
    // Only react when the status actually changed — the poll runs every couple
    // of seconds and an unchanged snapshot shouldn't rebuild the app.
    if (raw == _lastRaw) return;
    _lastRaw = raw;
    final map = jsonDecodeMap(raw);
    _status = map == null
        ? const EmbeddedServerStatus()
        : EmbeddedServerStatus.fromJson(map);
    // Keep the connectable loopback server entry in sync once running.
    if (_status.running) {
      await _syncServerEntry();
    }
    // Stop the poll loop once we settle into a terminal (non-running) state.
    if (!_status.running && !_status.starting) _stopPolling();
    notifyListeners();
  }

  /// Upsert the loopback [MotifServer] for the running server so the user can
  /// connect through the normal flow. No-op when the server only listens on
  /// Tailscale (no loopback endpoint).
  Future<void> _syncServerEntry() async {
    final endpoint = _status.loopbackEndpoint;
    if (endpoint == null) return;
    final desired = MotifServer(
      id: kEmbeddedServerId,
      name: 'This computer',
      host: endpoint.host,
      port: endpoint.port,
      token: _config.authEnabled ? _config.authToken : '',
      kind: ServerKind.direct,
    );
    MotifServer? existing;
    for (final s in _servers.servers) {
      if (s.id == kEmbeddedServerId) {
        existing = s;
        break;
      }
    }
    if (existing == null) {
      await _servers.add(desired);
    } else if (existing.host != desired.host ||
        existing.port != desired.port ||
        existing.token != desired.token) {
      await _servers.update(desired);
    }
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}
