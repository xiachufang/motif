/// Desktop-only owner of the *embedded* motifd server. This file is imported
/// only by the desktop entrypoint, so web/mobile builds never compile
/// motif-embed FFI or nativeapi-dependent code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../platform/secret_store.dart';
import '../../platform/motif_embed_ffi.dart';
import 'embedded_server_serialization.dart';
import 'embedded_server_service.dart';
import '../persistence/serialization.dart';

const String _kConfigKey = 'motif.embedded.v1';
const String kEmbeddedRzvJwtSecretKey = 'motif.embedded.rzv.jwt';

bool get _isDesktop =>
    Platform.isMacOS || Platform.isLinux || Platform.isWindows;

Future<EmbeddedServerService> createDesktopEmbeddedServerService(
  SharedPreferences prefs,
  SecretStore secrets,
) => DesktopEmbeddedServerService.create(prefs, secrets);

class DesktopEmbeddedServerService extends EmbeddedServerService {
  final SharedPreferences _prefs;
  final SecretStore _secrets;
  final LibMotifEmbed? _lib;

  Timer? _poll;
  Future<void> _configUpdates = Future<void>.value();

  DesktopEmbeddedServerService._(this._prefs, this._secrets, LibMotifEmbed? lib)
    : _lib = lib,
      super(available: lib != null, config: _loadConfig(_prefs));

  static EmbeddedServerConfig _loadConfig(SharedPreferences prefs) {
    final raw = prefs.getString(_kConfigKey);
    if (raw != null) {
      final map = jsonDecodeMap(raw);
      if (map != null) return embeddedServerConfigFromJson(map);
    }
    return const EmbeddedServerConfig();
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
    if (svc.available && svc.config.autostart) {
      unawaited(svc.start());
    }
    return svc;
  }

  Future<void> _loadRzvJwtAndMigrate() async {
    final legacyJwt = config.rzvJwt.trim();
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
    configState = config.copyWith(rzvJwt: jwt);
    await _persistNonSecretConfig();
  }

  Future<void> _persistNonSecretConfig() async {
    await _prefs.setString(
      _kConfigKey,
      jsonEncodeMap(config.toPersistedJson()),
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
    if (jwt != config.rzvJwt) {
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
    configState = next.copyWith(rzvJwt: jwt);
    await _persistNonSecretConfig();
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
    lib.start(jsonEncode(config.toRuntimeJson()));
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
    if (!status.starting && !status.running) _stopPolling();
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
    statusState = map == null
        ? const EmbeddedServerStatus()
        : embeddedServerStatusFromJson(map);
    // Stop the poll loop once we settle into a terminal (non-running) state.
    if (!status.running && !status.starting) _stopPolling();
    // The host observes this property and registers the running server as a
    // connectable target — the service itself stays client-agnostic.
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}
