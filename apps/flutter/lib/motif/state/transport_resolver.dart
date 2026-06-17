import 'dart:convert';
import 'dart:typed_data';

import '../models/settings.dart';
import '../net/proxy_client.dart';
import '../net/rzv/rzv_forwarder.dart';
import '../net/rzv/rzv_protocol.dart';
import '../net/ssh/ssh_forwarder.dart';
import '../platform/services.dart';
import 'connection_state.dart';

sealed class TransportResolution {
  const TransportResolution();
}

class TransportReady extends TransportResolution {
  final MotifServer target;
  final ProxySettings proxy;

  /// rzv end-to-end TLS cert pin (`sha256(cert.der)`), when the paired motifd
  /// runs with TLS. `null` for plaintext transports (tcp / tailscale / rzv
  /// without a pin in the pairing QR).
  final Uint8List? certPin;

  const TransportReady({
    required this.target,
    required this.proxy,
    this.certPin,
  });
}

class TransportBlocked extends TransportResolution {
  final ConnectionBlocker blocker;

  const TransportBlocked(this.blocker);
}

class TransportResolver {
  final PlatformServices platform;

  /// Live loopback forwarders for `rendezvous` servers, keyed by server id.
  /// Started lazily on [resolve] and torn down by [stopForwarder] when the
  /// owning connection disconnects or the server is removed.
  final Map<String, RzvForwarder> _rzvForwarders = {};

  /// Live loopback forwarders for `ssh` servers, keyed by server id.
  final Map<String, SshForwarder> _sshForwarders = {};

  /// Last runtime transport failure for a server, keyed by server id. Validation
  /// errors are computed from the server config; this map is only for failures
  /// discovered while starting a relay/tunnel.
  final Map<String, TransportViewState> _transportFailures = {};

  TransportResolver(this.platform);

  TransportViewState transportViewState(
    MotifServer server, {
    bool includeFailure = true,
  }) {
    final base = switch (server.kind) {
      ServerKind.direct => TransportViewState.direct(server),
      ServerKind.tailscale => TransportViewState.tailscale(
        server,
        platform.tailscale.state,
      ),
      ServerKind.rendezvous => TransportViewState.rendezvous(
        server,
        validationMessage: _validateRendezvous(server),
      ),
      ServerKind.ssh => TransportViewState.ssh(
        server,
        validationMessage: _validateSsh(server),
      ),
    };
    if (!base.isReady) return base;
    if (!includeFailure) return base;
    return _transportFailures[server.id] ?? base;
  }

  ConnectionBlocker? currentBlocker(MotifServer server) {
    final transport = transportViewState(server);
    if (transport.isReady) return null;
    return ConnectionBlocker.fromTransport(transport);
  }

  Future<TransportResolution> resolve(MotifServer server) async {
    final blocker = _preflightBlocker(server);
    if (blocker != null) return TransportBlocked(blocker);
    _transportFailures.remove(server.id);
    switch (server.kind) {
      case ServerKind.rendezvous:
        return _resolveRendezvous(server);
      case ServerKind.tailscale:
        return _resolveTailscale(server);
      case ServerKind.ssh:
        return _resolveSsh(server);
      case ServerKind.direct:
        return TransportReady(target: server, proxy: ProxySettings.none);
    }
  }

  ConnectionBlocker? _preflightBlocker(MotifServer server) {
    final transport = transportViewState(server, includeFailure: false);
    if (transport.isReady) return null;
    return ConnectionBlocker.fromTransport(transport);
  }

  /// Stop and forget the forwarder for [serverId], if any. Safe to call when
  /// none exists.
  Future<void> stopForwarder(String serverId) async {
    final rzv = _rzvForwarders.remove(serverId);
    final ssh = _sshForwarders.remove(serverId);
    _transportFailures.remove(serverId);
    await rzv?.stop();
    await ssh?.stop();
  }

  Future<TransportResolution> _resolveTailscale(MotifServer server) async {
    var target = server;
    try {
      final resolved = await platform.tailscale.resolveHost(server.host);
      if (resolved.isNotEmpty && resolved != server.host) {
        target = server.copyWith(host: resolved);
      }
    } catch (_) {
      // Preserve the previous behavior: MagicDNS resolution is helpful but not
      // required for a connection attempt when the tailnet backend is up.
    }

    return TransportReady(
      target: target,
      proxy: platform.tailscale.loopbackProxy ?? ProxySettings.none,
    );
  }

  /// Bring up (or reuse) a loopback forwarder that pairs with `motifd` through
  /// the relay, then connect to it as if it were a plain local server. The
  /// rest of the stack (RpcClient/WebSocket) is unaware of the rendezvous hop.
  Future<TransportResolution> _resolveRendezvous(MotifServer server) async {
    final relay = MotifServer.splitHostPort(server.relay);
    if (relay == null) {
      return TransportBlocked(
        ConnectionBlocker.fromTransport(
          TransportViewState.rendezvous(
            server,
            validationMessage:
                'Rendezvous server has no valid relay address (expected host:port)',
          ),
        ),
      );
    }

    final Uint8List token;
    try {
      token = _rzvToken(server.psk);
    } on FormatException catch (e) {
      return TransportBlocked(
        ConnectionBlocker.fromTransport(
          TransportViewState.rendezvous(
            server,
            validationMessage:
                'Rendezvous pairing secret invalid: ${e.message}',
          ),
        ),
      );
    }

    // End-to-end TLS pin (`pk` in the pairing QR). Present => motifd terminates
    // TLS and we connect over https/wss pinning sha256(cert.der) == pin.
    Uint8List? certPin;
    var scheme = 'http';
    if (server.pubKey.isNotEmpty) {
      try {
        certPin = base64Url.decode(base64Url.normalize(server.pubKey));
      } on FormatException {
        return TransportBlocked(
          ConnectionBlocker.fromTransport(
            TransportViewState.rendezvous(
              server,
              validationMessage: 'Rendezvous cert pin is not base64url',
            ),
          ),
        );
      }
      if (certPin.length != 32) {
        return TransportBlocked(
          ConnectionBlocker.fromTransport(
            TransportViewState.rendezvous(
              server,
              validationMessage: 'Rendezvous cert pin must be 32 bytes',
            ),
          ),
        );
      }
      scheme = 'https';
    }

    // Reuse a running forwarder for this server; restart it if the relay
    // endpoint changed (e.g. the server was re-paired with a new QR).
    var fwd = _rzvForwarders[server.id];
    if (fwd != null &&
        (fwd.relayHost != relay.$1 || fwd.relayPort != relay.$2)) {
      await stopForwarder(server.id);
      fwd = null;
    }
    fwd ??= _rzvForwarders[server.id] = RzvForwarder(
      relayHost: relay.$1,
      relayPort: relay.$2,
      token: token,
    );

    try {
      if (!fwd.isRunning) await fwd.start();
    } catch (e) {
      await stopForwarder(server.id);
      return _recordFailure(
        server,
        statusLabel: 'Rendezvous failed',
        message: 'Rendezvous forwarder failed to start: $e',
      );
    }

    final target = server.copyWith(
      host: '127.0.0.1',
      port: fwd.port,
      scheme: scheme,
    );
    return TransportReady(
      target: target,
      proxy: ProxySettings.none,
      certPin: certPin,
    );
  }

  /// Bring up (or reuse) a local SSH tunnel. Once started, motifd is reached
  /// through the loopback port exactly like a direct server.
  Future<TransportResolution> _resolveSsh(MotifServer server) async {
    final next = SshForwarder(
      sshHost: server.sshHost.trim(),
      sshPort: server.sshPort,
      username: server.sshUsername.trim(),
      authMethod: server.sshAuthMethod,
      password: server.sshPassword,
      privateKey: server.sshPrivateKey,
      privateKeyPassphrase: server.sshPrivateKeyPassphrase,
      remoteHost: server.host.trim(),
      remotePort: server.port,
    );

    var fwd = _sshForwarders[server.id];
    if (fwd != null && !fwd.matches(next)) {
      await stopForwarder(server.id);
      fwd = null;
    }
    fwd ??= _sshForwarders[server.id] = next;

    try {
      if (!fwd.isRunning) await fwd.start();
    } catch (e) {
      await stopForwarder(server.id);
      return _recordFailure(
        server,
        statusLabel: 'SSH failed',
        message: 'SSH tunnel failed to start: $e',
      );
    }

    final target = server.copyWith(
      host: '127.0.0.1',
      port: fwd.port,
      scheme: 'http',
    );
    return TransportReady(target: target, proxy: ProxySettings.none);
  }

  // The on-the-wire token is derived one-way from the 32-byte pairing secret
  // (HKDF-SHA256), matching `motif_server::rzv::derive_token`, so the relay
  // never sees the secret. The secret stays reserved for the P2 E2E layer.
  static Uint8List _rzvToken(String pskB64) {
    if (pskB64.isEmpty) throw const FormatException('missing pairing secret');
    final Uint8List psk;
    try {
      psk = base64Url.decode(base64Url.normalize(pskB64));
    } on FormatException {
      throw const FormatException('not base64url');
    }
    if (psk.length != RzvProtocol.tokenLength) {
      throw FormatException('must be ${RzvProtocol.tokenLength} bytes');
    }
    return RzvProtocol.deriveToken(psk);
  }

  static String? _validateRendezvous(MotifServer server) {
    final relay = MotifServer.splitHostPort(server.relay);
    if (relay == null) {
      return 'Rendezvous server has no valid relay address (expected host:port)';
    }
    try {
      _rzvToken(server.psk);
    } on FormatException catch (e) {
      return 'Rendezvous pairing secret invalid: ${e.message}';
    }
    if (server.pubKey.isNotEmpty) {
      Uint8List certPin;
      try {
        certPin = base64Url.decode(base64Url.normalize(server.pubKey));
      } on FormatException {
        return 'Rendezvous cert pin is not base64url';
      }
      if (certPin.length != 32) {
        return 'Rendezvous cert pin must be 32 bytes';
      }
    }
    return null;
  }

  static String? _validateSsh(MotifServer server) {
    if (server.host.trim().isEmpty) {
      return 'SSH server has no motifd host (as seen from the SSH server)';
    }
    if (server.port <= 0 || server.port > 65535) {
      return 'SSH server has an invalid motifd port';
    }
    if (server.sshHost.trim().isEmpty) {
      return 'SSH server has no SSH host';
    }
    if (server.sshPort <= 0 || server.sshPort > 65535) {
      return 'SSH server has an invalid SSH port';
    }
    if (server.sshUsername.trim().isEmpty) {
      return 'SSH server has no SSH username';
    }
    switch (server.sshAuthMethod) {
      case SshAuthMethod.password:
        if (server.sshPassword.isEmpty) {
          return 'SSH password is required';
        }
      case SshAuthMethod.privateKey:
        if (server.sshPrivateKey.trim().isEmpty) {
          return 'SSH private key is required';
        }
    }
    return null;
  }

  TransportBlocked _recordFailure(
    MotifServer server, {
    required String statusLabel,
    required String message,
  }) {
    final transport = TransportViewState.failure(
      kind: server.kind,
      statusLabel: statusLabel,
      message: message,
    );
    _transportFailures[server.id] = transport;
    return TransportBlocked(ConnectionBlocker.fromTransport(transport));
  }
}
