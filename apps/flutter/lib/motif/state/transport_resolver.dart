import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../log/log.dart';
import '../models/motif_proto.dart';
import '../models/settings.dart';
import '../net/proxy_client.dart';
import '../net/rzv/rzv_forwarder.dart';
import '../net/rzv/rzv_protocol.dart';
import '../net/ssh/ssh_bootstrapper.dart';
import '../net/ssh/ssh_forwarder.dart';
import '../net/ssh/ssh_forwarder_handle.dart';
import '../platform/services.dart';
import 'connection_state.dart';

typedef SshForwarderFactory =
    SshForwarderHandle Function({
      required String sshHost,
      required int sshPort,
      required String username,
      required SshAuthMethod authMethod,
      required String password,
      required String privateKey,
      required String privateKeyPassphrase,
      required String remoteHost,
      required int remotePort,
      required Duration connectTimeout,
    });

typedef SshAutoInitializer = Future<void> Function(MotifServer server);

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
  static const Duration _directProbeTimeout = Duration(seconds: 3);

  final PlatformServices platform;
  final SshForwarderFactory _sshForwarderFactory;
  final SshAutoInitializer _sshAutoInitializer;

  /// Live loopback forwarders for `rendezvous` servers, keyed by server id.
  /// Started lazily on [resolve] and torn down by [stopForwarder] when the
  /// owning connection disconnects or the server is removed.
  final Map<String, RzvForwarder> _rzvForwarders = {};

  /// LAN-direct candidates learned from a rendezvous server's `/ping`, keyed by
  /// server id. In-memory only (never persisted): each session starts on the
  /// relay, learns candidates via [learnRzvDirect], then [resolve] probes them
  /// to upgrade to a direct connection. Cleared by [forgetRzvDirect] on a
  /// deliberate disconnect — NOT by [stopForwarder], so reconnects stay direct.
  final Map<String, _RzvDirect> _rzvDirect = {};

  /// Live loopback forwarders for `ssh` servers, keyed by server id.
  final Map<String, SshForwarderHandle> _sshForwarders = {};

  /// Last runtime transport failure for a server, keyed by server id. Validation
  /// errors are computed from the server config; this map is only for failures
  /// discovered while starting a relay/tunnel.
  final Map<String, TransportViewState> _transportFailures = {};

  TransportResolver(
    this.platform, {
    SshForwarderFactory? sshForwarderFactory,
    SshAutoInitializer? sshAutoInitializer,
  }) : _sshForwarderFactory = sshForwarderFactory ?? _defaultSshForwarder,
       _sshAutoInitializer = sshAutoInitializer ?? _defaultSshAutoInitialize;

  static SshForwarderHandle _defaultSshForwarder({
    required String sshHost,
    required int sshPort,
    required String username,
    required SshAuthMethod authMethod,
    required String password,
    required String privateKey,
    required String privateKeyPassphrase,
    required String remoteHost,
    required int remotePort,
    required Duration connectTimeout,
  }) => SshForwarder(
    sshHost: sshHost,
    sshPort: sshPort,
    username: username,
    authMethod: authMethod,
    password: password,
    privateKey: privateKey,
    privateKeyPassphrase: privateKeyPassphrase,
    remoteHost: remoteHost,
    remotePort: remotePort,
    connectTimeout: connectTimeout,
  );

  static Future<void> _defaultSshAutoInitialize(MotifServer server) =>
      SshBootstrapper(server: server).ensureMotifd();

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
        return _resolveDirect(server);
    }
  }

  ConnectionBlocker? _preflightBlocker(MotifServer server) {
    final transport = transportViewState(server, includeFailure: false);
    if (transport.isReady) return null;
    return ConnectionBlocker.fromTransport(transport);
  }

  /// Stop and forget the forwarder for [serverId], if any. Safe to call when
  /// none exists. Deliberately does NOT clear learned LAN-direct candidates —
  /// the relay→direct upgrade stops the forwarder while keeping the candidates.
  Future<void> stopForwarder(String serverId) async {
    final rzv = _rzvForwarders.remove(serverId);
    final ssh = _sshForwarders.remove(serverId);
    _transportFailures.remove(serverId);
    await rzv?.stop();
    await ssh?.stop();
  }

  /// Record the LAN-direct candidates a rendezvous server advertised over
  /// `/ping`. Returns `true` only when candidates become available for the
  /// first time (no entry yet) — the controller uses that as the cue to kick an
  /// immediate reconnect so [resolve] can upgrade onto the direct path. Repeat
  /// calls (already direct, or refreshing the same set) return `false` so we
  /// don't reconnect on a loop. IPv6 candidates are dropped (LAN-direct targets
  /// IPv4; link-local IPv6 is already filtered server-side).
  bool learnRzvDirect(MotifServer server, PingInfo? ping) {
    if (server.kind != ServerKind.rendezvous) return false;
    final port = ping?.rzvDirectPort;
    final v4 = (ping?.rzvDirectAddrs ?? const <String>[])
        .where((a) => !a.contains(':'))
        .toList(growable: false);
    if (port == null || port <= 0 || v4.isEmpty) {
      // The server no longer advertises a usable direct port; drop stale state.
      _rzvDirect.remove(server.id);
      return false;
    }
    final firstTime = !_rzvDirect.containsKey(server.id);
    _rzvDirect[server.id] = _RzvDirect(port: port, addrs: v4);
    return firstTime;
  }

  /// Forget any learned LAN-direct candidates for [serverId], so the next
  /// session starts on the relay again. Call on a deliberate disconnect /
  /// server removal — not on the transient forwarder teardown of an upgrade.
  void forgetRzvDirect(String serverId) {
    _rzvDirect.remove(serverId);
  }

  /// Probe [addrs] (at [port]) concurrently and resolve to the first that
  /// answers as a motif-server, or `null` if none do within the per-probe
  /// timeout. When [certPin] is set the probe runs over TLS (`https`) pinning
  /// that cert; otherwise plaintext. Never throws.
  Future<String?> _firstReachableDirect(
    List<String> addrs,
    int port, {
    Uint8List? certPin,
  }) {
    if (addrs.isEmpty) return Future.value(null);
    final sw = Stopwatch()..start();
    Log.i(
      'direct probe begin candidates=${addrs.length} port=$port tls=${certPin != null}',
      name: 'motif.resume',
    );
    final completer = Completer<String?>();
    var pending = addrs.length;
    for (final addr in addrs) {
      _probeDirect(addr, port, certPin: certPin).then((ok) {
        if (completer.isCompleted) return;
        if (ok) {
          Log.i(
            'direct probe hit address=$addr took=${sw.elapsedMilliseconds}ms',
            name: 'motif.resume',
          );
          completer.complete(addr);
        } else if (--pending == 0) {
          Log.i(
            'direct probe miss candidates=${addrs.length} '
            'took=${sw.elapsedMilliseconds}ms',
            name: 'motif.resume',
          );
          completer.complete(null);
        }
      });
    }
    return completer.future;
  }

  /// `GET {http,https}://addr:port/ping`, true iff it answers as a
  /// motif-server. With [certPin] it pins motifd's self-signed cert. Short
  /// timeout so a dead candidate doesn't stall the connect.
  Future<bool> _probeDirect(String addr, int port, {Uint8List? certPin}) async {
    final scheme = certPin == null ? 'http' : 'https';
    final client = makeHttpClient(ProxySettings.none, certPin: certPin);
    try {
      final resp = await client
          .get(Uri.parse('$scheme://$addr:$port/ping'))
          .timeout(_directProbeTimeout);
      if (resp.statusCode != 200) return false;
      final info = PingInfo.fromJson(
        jsonDecode(resp.body) as Map<String, Object?>,
      );
      return info.isMotifServer;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Parse the base64url cert pin (`pk`). `null` when empty (plaintext); throws
  /// [FormatException] on malformed / non-32-byte input.
  static Uint8List? _parsePin(String pubKeyB64) {
    if (pubKeyB64.isEmpty) return null;
    final Uint8List pin;
    try {
      pin = base64Url.decode(base64Url.normalize(pubKeyB64));
    } on FormatException {
      throw const FormatException('not base64url');
    }
    if (pin.length != 32) {
      throw const FormatException('must be 32 bytes');
    }
    return pin;
  }

  /// The motifd access bearer (`base64url(deriveAuthBearer(psk))`) the client
  /// sends as `Authorization: Bearer`. Empty when the server has no psk (a
  /// manually-typed direct/loopback server with no pairing secret).
  static String _authBearer(String pskB64) {
    if (pskB64.isEmpty) return '';
    final Uint8List psk;
    try {
      psk = base64Url.decode(base64Url.normalize(pskB64));
    } on FormatException {
      return '';
    }
    if (psk.length != RzvProtocol.tokenLength) return '';
    return base64Url
        .encode(RzvProtocol.deriveAuthBearer(psk))
        .replaceAll('=', '');
  }

  Future<TransportResolution> _resolveTailscale(MotifServer server) async {
    var target = server;
    try {
      final resolved = await platform.tailscale.resolveHost(server.host);
      if (resolved.isNotEmpty && resolved != server.host) {
        target = server.copyWith(host: resolved);
      }
    } catch (_) {
      // MagicDNS resolution is optional when the tailnet backend is up.
    }

    return TransportReady(
      target: target,
      proxy: platform.tailscale.loopbackProxy ?? ProxySettings.none,
    );
  }

  /// Resolve a `direct` server. A **paired** direct server (from a no-relay QR)
  /// carries [MotifServer.directHosts] (all of motifd's NIC addresses), a cert
  /// pin, and a psk: probe the candidates over TLS and dial whichever is
  /// reachable, authenticating with the psk bearer. A **manually-typed** direct
  /// server has no candidates — connect to its host as configured (plaintext,
  /// its own token), unchanged from before.
  Future<TransportResolution> _resolveDirect(MotifServer server) async {
    if (server.directHosts.isEmpty) {
      // Manually-typed direct server (no candidate list): connect as configured.
      // If it carries a psk (e.g. the embedded loopback server in relay mode),
      // send the derived bearer; otherwise leave its token as-is.
      final bearer = _authBearer(server.psk);
      final target = bearer.isEmpty ? server : server.copyWith(token: bearer);
      return TransportReady(target: target, proxy: ProxySettings.none);
    }

    final Uint8List? certPin;
    try {
      certPin = _parsePin(server.pubKey);
    } on FormatException catch (e) {
      return _recordFailure(
        server,
        statusLabel: 'Direct failed',
        message: 'Direct server cert pin ${e.message}',
      );
    }
    final scheme = certPin != null ? 'https' : 'http';
    final bearer = _authBearer(server.psk);

    // Web can't reach arbitrary LAN IPs / pin certs; just take the first.
    if (kIsWeb) {
      return TransportReady(
        target: server.copyWith(
          host: server.directHosts.first,
          scheme: scheme,
          token: bearer,
        ),
        proxy: ProxySettings.none,
        certPin: certPin,
      );
    }

    final hit = await _firstReachableDirect(
      server.directHosts,
      server.port,
      certPin: certPin,
    );
    if (hit == null) {
      return _recordFailure(
        server,
        statusLabel: 'Direct unreachable',
        message:
            'None of ${server.directHosts.length} advertised address(es) reachable',
      );
    }
    return TransportReady(
      target: server.copyWith(host: hit, scheme: scheme, token: bearer),
      proxy: ProxySettings.none,
      certPin: certPin,
    );
  }

  /// Bring up (or reuse) a loopback forwarder that pairs with `motifd` through
  /// the relay, then connect to it as if it were a plain local server. The
  /// rest of the stack (RpcClient/WebSocket) is unaware of the rendezvous hop.
  Future<TransportResolution> _resolveRendezvous(MotifServer server) async {
    final relay = MotifServer.splitRelayEndpoint(server.relay);
    if (relay == null) {
      return TransportBlocked(
        ConnectionBlocker.fromTransport(
          TransportViewState.rendezvous(
            server,
            validationMessage:
                'Rendezvous server has no valid WSS relay address',
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

    // TLS pin (`pk` in the QR): the client verifies motifd's self-signed cert
    // by `sha256(cert.der) == pin` over both the relay and the LAN-direct path.
    final Uint8List? certPin;
    try {
      certPin = _parsePin(server.pubKey);
    } on FormatException catch (e) {
      return TransportBlocked(
        ConnectionBlocker.fromTransport(
          TransportViewState.rendezvous(
            server,
            validationMessage: 'Rendezvous cert pin ${e.message}',
          ),
        ),
      );
    }
    final scheme = certPin != null ? 'https' : 'http';
    // psk-derived motifd access bearer, sent on every connection (relay or
    // direct) over its TLS channel.
    final bearer = _authBearer(server.psk);

    // Same-LAN fast path: if this server's direct candidates have been learned
    // (from a prior connection's /ping), probe them (TLS-pinned) and, on a hit,
    // dial motifd directly — bypassing the relay entirely. Needs the pin (the
    // direct port is TLS). Skipped on web (can't reach arbitrary LAN IPs). On a
    // miss (e.g. we've left the LAN) we fall through to the relay path; the
    // candidates stay cached so a later reconnect can try again.
    if (!kIsWeb && certPin != null) {
      final direct = _rzvDirect[server.id];
      if (direct != null) {
        final hit = await _firstReachableDirect(
          direct.addrs,
          direct.port,
          certPin: certPin,
        );
        if (hit != null) {
          await stopForwarder(server.id); // release the relay loopback
          Log.i(
            'rzv ${server.id}: upgraded to LAN-direct https://$hit:${direct.port}',
            name: 'motif.rzv',
          );
          return TransportReady(
            target: server.copyWith(
              host: hit,
              port: direct.port,
              scheme: 'https',
              token: bearer,
            ),
            proxy: ProxySettings.none,
            certPin: certPin,
          );
        }
      }
    }

    // Reuse a running forwarder for this server; restart it if the relay
    // endpoint changed (e.g. the server was re-paired with a new QR).
    var fwd = _rzvForwarders[server.id];
    if (fwd != null &&
        (fwd.relayHost != relay.host ||
            fwd.relayPort != relay.port ||
            fwd.relayScheme != relay.scheme)) {
      await stopForwarder(server.id);
      fwd = null;
    }
    fwd ??= _rzvForwarders[server.id] = RzvForwarder(
      relayHost: relay.host,
      relayPort: relay.port,
      relayScheme: relay.scheme,
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
      token: bearer,
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
    if (server.sshAutoInitialize) {
      try {
        await _sshAutoInitializer(server);
      } catch (e) {
        return _recordFailure(
          server,
          statusLabel: 'SSH init failed',
          message: _sshInitFailureMessage(e),
        );
      }
    }

    final next = _sshForwarderFactory(
      sshHost: server.sshHost.trim(),
      sshPort: server.sshPort,
      username: server.sshUsername.trim(),
      authMethod: server.sshAuthMethod,
      password: server.sshPassword,
      privateKey: server.sshPrivateKey,
      privateKeyPassphrase: server.sshPrivateKeyPassphrase,
      remoteHost: server.host.trim(),
      remotePort: server.port,
      connectTimeout: const Duration(seconds: 15),
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
    final relay = MotifServer.splitRelayEndpoint(server.relay);
    if (relay == null) {
      return 'Rendezvous server has no valid WSS relay address';
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

  static String _sshInitFailureMessage(Object error) =>
      error is SshBootstrapException
      ? error.toString()
      : 'SSH auto-initialize failed: $error';
}

/// LAN-direct candidates for one rendezvous server: the plaintext port plus the
/// IPv4 addresses to try at it, learned from the server's `/ping`.
class _RzvDirect {
  const _RzvDirect({required this.port, required this.addrs});

  final int port;
  final List<String> addrs;
}
