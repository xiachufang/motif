/// Desktop-only owner of the *embedded* motifd server. This file is imported
/// only by the desktop entrypoint, so web/mobile builds never compile
/// motif-embed FFI or nativeapi-dependent code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/motif_embed_ffi.dart';
import 'embedded_server_service.dart';
// jsonDecodeMap / jsonEncodeMap live here (the ServerStore type is no longer
// used — the service is client-agnostic).
import 'stores.dart';

const String _kConfigKey = 'motif.embedded.v1';

bool get _isDesktop =>
    Platform.isMacOS || Platform.isLinux || Platform.isWindows;

EmbeddedListenMode _listenModeFromWire(Object? v) => switch (v) {
  'lan' => EmbeddedListenMode.lan,
  'off' => EmbeddedListenMode.off,
  _ => EmbeddedListenMode.loopback,
};

extension DesktopEmbeddedServerConfigJson on EmbeddedServerConfig {
  Map<String, Object?> toJson() => {
    'listen_mode': listenMode.name,
    'port': port,
    'tailscale': {
      'enabled': tsEnabled,
      'hostname': tsHostname,
      'authkey': tsAuthkey,
      'control_url': tsControlUrl,
    },
    'rzv': {'enabled': rzvEnabled, 'relay': rzvRelay},
    'push_relay_url': pushRelayUrl,
    'autostart': autostart,
  };
}

EmbeddedServerConfig _configFromJson(Map<String, Object?> j) {
  final ts = (j['tailscale'] as Map?)?.cast<String, Object?>() ?? const {};
  final rzv = (j['rzv'] as Map?)?.cast<String, Object?>() ?? const {};
  return EmbeddedServerConfig(
    listenMode: _listenModeFromWire(j['listen_mode']),
    port: (j['port'] as num?)?.toInt() ?? 7777,
    tsEnabled: ts['enabled'] == true,
    tsHostname: (ts['hostname'] as String?) ?? '',
    tsAuthkey: (ts['authkey'] as String?) ?? '',
    tsControlUrl: (ts['control_url'] as String?) ?? '',
    rzvEnabled: rzv['enabled'] == true,
    rzvRelay: (rzv['relay'] as String?) ?? '',
    pushRelayUrl: (j['push_relay_url'] as String?) ?? kDefaultPushRelayAddress,
    autostart: j['autostart'] == true,
  );
}

EmbeddedServerStatus _statusFromJson(Map<String, Object?> j) {
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

Future<EmbeddedServerService> createDesktopEmbeddedServerService(
  SharedPreferences prefs,
) => DesktopEmbeddedServerService.create(prefs);

class DesktopEmbeddedServerService extends EmbeddedServerService {
  final SharedPreferences _prefs;
  final LibMotifEmbed? _lib;

  EmbeddedServerConfig _config = const EmbeddedServerConfig();
  EmbeddedServerStatus _status = const EmbeddedServerStatus();
  Timer? _poll;

  DesktopEmbeddedServerService._(this._prefs, this._lib) {
    final raw = _prefs.getString(_kConfigKey);
    if (raw != null) {
      final map = jsonDecodeMap(raw);
      if (map != null) _config = _configFromJson(map);
    }
  }

  /// Build the service, loading the native library and initializing logging on
  /// desktop. Best-effort autostart if the saved config asks for it. The
  /// service is client-agnostic — registering the running server as a
  /// connectable target is the host's (AppState's) job, by observing status.
  static Future<DesktopEmbeddedServerService> create(
    SharedPreferences prefs,
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
    final svc = DesktopEmbeddedServerService._(prefs, lib);
    if (svc.available && svc._config.autostart) {
      unawaited(svc.start());
    }
    return svc;
  }

  /// Whether the embedded-server capability is present (desktop + library
  /// loaded). When false, the tray/settings hide the feature.
  @override
  bool get available => _lib != null;

  @override
  EmbeddedServerConfig get config => _config;

  @override
  EmbeddedServerStatus get status => _status;

  @override
  EmbeddedRunState get phase => _status.phase;

  @override
  Future<void> updateConfig(EmbeddedServerConfig next) async {
    _config = next;
    await _prefs.setString(_kConfigKey, jsonEncodeMap(next.toJson()));
    notifyListeners();
  }

  /// Generate a fresh bearer token via the native RNG (empty if unavailable).
  @override
  String generateToken() => _lib?.generateToken() ?? '';

  /// Start the embedded server with the current config. Non-blocking; status
  /// is reflected through [status] as the poller advances.
  @override
  Future<void> start() async {
    final lib = _lib;
    if (lib == null) return;
    lib.start(jsonEncode(_config.toJson()));
    _startPolling();
    await _refresh();
  }

  /// Stop the embedded server. Idempotent.
  @override
  Future<void> stop() async {
    final lib = _lib;
    if (lib == null) return;
    lib.stop();
    await _refresh();
    if (!_status.starting && !_status.running) _stopPolling();
  }

  /// Last [n] log lines from the native ring (empty list if unavailable).
  @override
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
    _status = map == null ? const EmbeddedServerStatus() : _statusFromJson(map);
    // Stop the poll loop once we settle into a terminal (non-running) state.
    if (!_status.running && !_status.starting) _stopPolling();
    // The host (AppState) listens to this notifier and registers the running
    // server as a connectable target — the service itself stays client-agnostic.
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}
