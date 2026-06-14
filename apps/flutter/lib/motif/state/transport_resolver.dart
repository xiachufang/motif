import 'dart:convert';
import 'dart:typed_data';

import '../models/settings.dart';
import '../net/proxy_client.dart';
import '../net/rzv/rzv_forwarder.dart';
import '../net/rzv/rzv_protocol.dart';
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

class TransportFailed extends TransportResolution {
  final String message;

  const TransportFailed(this.message);
}

class TransportResolver {
  final PlatformServices platform;

  /// Live loopback forwarders for `rendezvous` servers, keyed by server id.
  /// Started lazily on [resolve] and torn down by [stopForwarder] when the
  /// owning connection disconnects or the server is removed.
  final Map<String, RzvForwarder> _forwarders = {};

  TransportResolver(this.platform);

  ConnectionBlocker? currentBlocker(MotifServer server) {
    if (server.kind != ServerKind.tailscale) return null;
    final tailscale = platform.tailscale.state;
    if (tailscale.status == TailscaleStatus.running) return null;
    return ConnectionBlocker.tailscale(tailscale);
  }

  Future<TransportResolution> resolve(MotifServer server) async {
    switch (server.kind) {
      case ServerKind.rendezvous:
        return _resolveRendezvous(server);
      case ServerKind.tailscale:
        return _resolveTailscale(server);
      case ServerKind.direct:
        return TransportReady(target: server, proxy: ProxySettings.none);
    }
  }

  /// Stop and forget the forwarder for [serverId], if any. Safe to call when
  /// none exists.
  Future<void> stopForwarder(String serverId) async {
    final fwd = _forwarders.remove(serverId);
    await fwd?.stop();
  }

  Future<TransportResolution> _resolveTailscale(MotifServer server) async {
    final blocker = currentBlocker(server);
    if (blocker != null) return TransportBlocked(blocker);

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
    final relay = _parseHostPort(server.relay);
    if (relay == null) {
      return const TransportFailed(
        'rendezvous server has no valid relay address (expected host:port)',
      );
    }

    final Uint8List token;
    try {
      token = _rzvToken(server.psk);
    } on FormatException catch (e) {
      return TransportFailed('rendezvous pairing secret invalid: ${e.message}');
    }

    // End-to-end TLS pin (`pk` in the pairing QR). Present => motifd terminates
    // TLS and we connect over https/wss pinning sha256(cert.der) == pin.
    Uint8List? certPin;
    var scheme = 'http';
    if (server.pubKey.isNotEmpty) {
      try {
        certPin = base64Url.decode(base64Url.normalize(server.pubKey));
      } on FormatException {
        return const TransportFailed('rendezvous cert pin is not base64url');
      }
      if (certPin.length != 32) {
        return const TransportFailed('rendezvous cert pin must be 32 bytes');
      }
      scheme = 'https';
    }

    // Reuse a running forwarder for this server; restart it if the relay
    // endpoint changed (e.g. the server was re-paired with a new QR).
    var fwd = _forwarders[server.id];
    if (fwd != null &&
        (fwd.relayHost != relay.$1 || fwd.relayPort != relay.$2)) {
      await stopForwarder(server.id);
      fwd = null;
    }
    fwd ??= _forwarders[server.id] = RzvForwarder(
      relayHost: relay.$1,
      relayPort: relay.$2,
      token: token,
    );

    try {
      if (!fwd.isRunning) await fwd.start();
    } catch (e) {
      await stopForwarder(server.id);
      return TransportFailed('rendezvous forwarder failed to start: $e');
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

  static (String, int)? _parseHostPort(String s) {
    final i = s.lastIndexOf(':');
    if (i <= 0 || i == s.length - 1) return null;
    final host = s.substring(0, i);
    final port = int.tryParse(s.substring(i + 1));
    if (port == null || port <= 0 || port > 65535) return null;
    return (host, port);
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
}
