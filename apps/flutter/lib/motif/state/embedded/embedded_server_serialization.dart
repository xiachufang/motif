/// JSON adapters for embedded-server persistence and FFI payloads.
library;

import 'embedded_server_models.dart';

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
    'autostart': autostart,
  };

  /// Full in-memory configuration passed directly to the embedded Rust server.
  Map<String, Object?> toRuntimeJson() => {
    'listen_mode': listenMode.name,
    'port': port,
    'tailscale': {
      'enabled': tsEnabled,
      'hostname': tsHostname,
      'authkey': tsAuthkey,
      'control_url': tsControlUrl,
    },
    'rzv': {'enabled': rzvEnabled, 'relay': rzvRelay, 'jwt': rzvJwt},
    'push_relay_url': pushRelayUrl,
    'autostart': autostart,
  };
}

/// Decode persisted settings defensively. Config key `motif.embedded.v1` has
/// gained fields over time, so older installs continue to load with defaults.
EmbeddedServerConfig embeddedServerConfigFromJson(Map<String, Object?> json) {
  const defaults = EmbeddedServerConfig();
  final tailscale = _jsonObject(json['tailscale']);
  final rendezvous = _jsonObject(json['rzv']);
  final port = json['port'];
  return EmbeddedServerConfig(
    listenMode: _listenModeFromWire(json['listen_mode']),
    port: port is num ? port.toInt() : defaults.port,
    tsEnabled: _jsonBool(tailscale['enabled'], defaults.tsEnabled),
    tsHostname: _jsonString(tailscale['hostname'], defaults.tsHostname),
    tsAuthkey: _jsonString(tailscale['authkey'], defaults.tsAuthkey),
    tsControlUrl: _jsonString(tailscale['control_url'], defaults.tsControlUrl),
    rzvEnabled: _jsonBool(rendezvous['enabled'], defaults.rzvEnabled),
    rzvRelay: _jsonString(rendezvous['relay'], defaults.rzvRelay),
    rzvJwt: _jsonString(rendezvous['jwt'], defaults.rzvJwt),
    pushRelayUrl: _jsonString(json['push_relay_url'], defaults.pushRelayUrl),
    autostart: _jsonBool(json['autostart'], defaults.autostart),
  );
}

EmbeddedServerStatus embeddedServerStatusFromJson(Map<String, Object?> json) {
  final tailscale = (json['tailscale'] as Map?)?.cast<String, Object?>();
  return EmbeddedServerStatus(
    running: json['running'] == true,
    starting: json['starting'] == true,
    boundAddrs:
        (json['bound_addrs'] as List?)
            ?.map((entry) => entry.toString())
            .toList() ??
        const [],
    sessionCount: (json['session_count'] as num?)?.toInt() ?? 0,
    tailscaleState: tailscale?['backend_state'] as String?,
    authUrl: json['auth_url'] as String?,
    pairingUri: json['pairing_uri'] as String?,
    relayError: json['relay_error'] as String?,
    error: json['error'] as String?,
  );
}
