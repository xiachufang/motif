/// Desktop-only owner of the *embedded* motifd server. This file is imported
/// only by the desktop entrypoint, so web/mobile builds never compile
/// motif-embed FFI or nativeapi-dependent code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/secret_store.dart';
import '../platform/motif_embed_ffi.dart';
import 'embedded_server_service.dart';
// jsonDecodeMap / jsonEncodeMap live here (the ServerStore type is no longer
// used — the service is client-agnostic).
import 'stores.dart';

const String _kConfigKey = 'motif.embedded.v1';
const String kEmbeddedRzvJwtSecretKey = 'motif.embedded.rzv.jwt';

bool get _isDesktop =>
    Platform.isMacOS || Platform.isLinux || Platform.isWindows;

EmbeddedListenMode _listenModeFromWire(Object? value) => switch (value) {
  'lan' => EmbeddedListenMode.lan,
  _ => EmbeddedListenMode.loopback,
};

Map<String, Object?> _jsonObject(Object? value) {
  if (value is! Map) return const {};
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

String _jsonString(Object? value, String fallback) =>
    value is String ? value : fallback;

bool _jsonBool(Object? value, bool fallback) =>
    value is bool ? value : fallback;

extension DesktopEmbeddedServerConfigJson on EmbeddedServerConfig {
  /// Non-secret settings safe to persist in SharedPreferences.
  Map<String, Object?> toPersistedJson() => {
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
    'shell': shell,
    'autostart': autostart,
  };

  /// Full in-memory configuration passed directly to the embedded Rust server.
  Map<String, Object?> toRuntimeJson() {
    final json = toPersistedJson();
    json['rzv'] = {'enabled': rzvEnabled, 'relay': rzvRelay, 'jwt': rzvJwt};
    return json;
  }
}

/// Decode persisted settings defensively. Config key `motif.embedded.v1` has
/// gained fields over time, so older installs must keep working and expose the
/// missing values in Settings instead of aborting before Flutter's first frame.
EmbeddedServerConfig embeddedServerConfigFromJson(Map<String, Object?> j) {
  const defaults = EmbeddedServerConfig();
  final ts = _jsonObject(j['tailscale']);
  final rzv = _jsonObject(j['rzv']);
  final port = j['port'];
  return EmbeddedServerConfig(
    listenMode: _listenModeFromWire(j['listen_mode']),
    port: port is num ? port.toInt() : defaults.port,
    tsEnabled: _jsonBool(ts['enabled'], defaults.tsEnabled),
    tsHostname: _jsonString(ts['hostname'], defaults.tsHostname),
    tsAuthkey: _jsonString(ts['authkey'], defaults.tsAuthkey),
    tsControlUrl: _jsonString(ts['control_url'], defaults.tsControlUrl),
    rzvEnabled: _jsonBool(rzv['enabled'], defaults.rzvEnabled),
    rzvRelay: _jsonString(rzv['relay'], defaults.rzvRelay),
    rzvJwt: _jsonString(rzv['jwt'], defaults.rzvJwt),
    pushRelayUrl: _jsonString(j['push_relay_url'], defaults.pushRelayUrl),
    shell: _jsonString(j['shell'], defaults.shell),
    autostart: _jsonBool(j['autostart'], defaults.autostart),
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
    relayError: j['relay_error'] as String?,
    error: j['error'] as String?,
  );
}

Future<EmbeddedServerService> createDesktopEmbeddedServerService(
  SharedPreferences prefs,
  SecretStore secrets,
) => DesktopEmbeddedServerService.create(prefs, secrets);

class DesktopEmbeddedServerService extends EmbeddedServerService {
  final SharedPreferences _prefs;
  final SecretStore _secrets;
  final LibMotifEmbed? _lib;

  EmbeddedServerConfig _config = const EmbeddedServerConfig();
  EmbeddedServerStatus _status = const EmbeddedServerStatus();
  Timer? _poll;
  Future<void> _configUpdates = Future<void>.value();

  DesktopEmbeddedServerService._(this._prefs, this._secrets, this._lib) {
    final raw = _prefs.getString(_kConfigKey);
    if (raw != null) {
      final map = jsonDecodeMap(raw);
      if (map != null) _config = embeddedServerConfigFromJson(map);
    }
  }

  /// Build the service, loading the native library and initializing logging on
  /// desktop. Best-effort autostart if the saved config asks for it. The
  /// service is client-agnostic — registering the running server as a
  /// connectable target is the host's (AppState's) job, by observing status.
  static Future<DesktopEmbeddedServerService> create(
    SharedPreferences prefs,
    SecretStore secrets,
  ) async {
    LibMotifEmbed? lib;
    if (_isDesktop) {
      final candidate = LibMotifEmbed.tryOpenDefault();
      if (candidate != null) {
        String logDir;
        try {
          final support = await getApplicationSupportDirectory();
          logDir = '${support.path}/motif/logs';
        } catch (_) {
          logDir = '${Directory.systemTemp.path}/motif/logs';
        }
        // init creates the Rust runtime and process-global server state in
        // addition to configuring logs. Do not advertise the capability when
        // that mandatory initialization failed.
        try {
          if (candidate.init(logDir) == 0) lib = candidate;
        } catch (_) {}
      }
    }
    final svc = DesktopEmbeddedServerService._(prefs, secrets, lib);
    await svc._loadRzvJwtAndMigrate();
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

  Future<void> _loadRzvJwtAndMigrate() async {
    final legacyJwt = _config.rzvJwt.trim();
    if (!_secrets.isAvailable) {
      if (legacyJwt.isNotEmpty) {
        throw StateError(
          'Secure storage is required to migrate the relay JWT.',
        );
      }
      // Rewrite even without a JWT so an empty legacy `rzv.jwt` field is
      // removed from the ordinary preferences document.
      await _persistNonSecretConfig();
      return;
    }

    final storedJwt = (await _secrets.read(kEmbeddedRzvJwtSecretKey))?.trim();
    final jwt = storedJwt == null || storedJwt.isEmpty ? legacyJwt : storedJwt;
    if ((storedJwt == null || storedJwt.isEmpty) && legacyJwt.isNotEmpty) {
      // Write first and only then erase the plaintext copy, so a Keychain /
      // credential-manager failure never loses the existing credential.
      await _secrets.write(kEmbeddedRzvJwtSecretKey, legacyJwt);
    }
    _config = _config.copyWith(rzvJwt: jwt);
    await _persistNonSecretConfig();
  }

  Future<void> _persistNonSecretConfig() async {
    await _prefs.setString(
      _kConfigKey,
      jsonEncodeMap(_config.toPersistedJson()),
    );
  }

  @override
  Future<void> updateConfig(EmbeddedServerConfig next) {
    final operation = _configUpdates.then((_) => _applyConfig(next));
    // Keep later edits ordered even if one write fails, while still returning
    // the original error to the caller that initiated the failed update.
    _configUpdates = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _applyConfig(EmbeddedServerConfig next) async {
    final jwt = next.rzvJwt.trim();
    if (jwt != _config.rzvJwt) {
      if (!_secrets.isAvailable && jwt.isNotEmpty) {
        throw StateError('Secure storage is required for the relay JWT.');
      }
      if (_secrets.isAvailable) {
        if (jwt.isEmpty) {
          await _secrets.delete(kEmbeddedRzvJwtSecretKey);
        } else {
          await _secrets.write(kEmbeddedRzvJwtSecretKey, jwt);
        }
      }
    }
    _config = next.copyWith(rzvJwt: jwt);
    await _persistNonSecretConfig();
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
    lib.start(jsonEncode(_config.toRuntimeJson()));
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

  @override
  Future<List<RegisteredPushToken>> registeredPushTokens() async {
    final lib = _lib;
    if (lib == null) return const [];
    final map = jsonDecodeMap(lib.pushDevicesJson());
    if (map == null) return const [];
    final error = map['error'] as String?;
    if (error != null && error.isNotEmpty) {
      throw StateError(error);
    }
    final devices = map['devices'] as List? ?? const [];
    return devices
        .whereType<Map>()
        .map((e) => RegisteredPushToken.fromJson(e.cast<String, Object?>()))
        .toList();
  }

  @override
  Future<PushTestResult> sendTestPush(String deviceToken) async {
    final lib = _lib;
    if (lib == null) {
      throw StateError('embedded server is unavailable');
    }
    final map = jsonDecodeMap(lib.sendTestPush(deviceToken));
    if (map == null) {
      throw StateError('invalid test push response');
    }
    final error = map['error'] as String?;
    if (error != null && error.isNotEmpty) {
      throw StateError(error);
    }
    return PushTestResult(
      sent: map['sent'] == true,
      pruned: map['pruned'] == true,
    );
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
