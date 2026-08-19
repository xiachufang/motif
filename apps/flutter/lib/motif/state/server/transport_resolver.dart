import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, listEquals;
import 'package:flutter_observation/flutter_observation.dart';
import 'package:http/http.dart' as http;

import '../../log/log.dart';
import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../net/proxy_client.dart';
import '../../net/rpc_error.dart';
import '../../net/rzv/rzv_forwarder.dart';
import '../../net/rzv/rzv_protocol.dart';
import '../../net/ssh/ssh_bootstrapper.dart';
import '../../net/ssh/ssh_forwarder.dart';
import '../../net/ssh/ssh_forwarder_handle.dart';
import '../../net/wsl/wsl_bootstrapper.dart';
import '../../platform/services.dart';
import '../connection/connection_state.dart';
import '../persistence/rzv_route_cache.dart';

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
typedef WslAutoInitializer = Future<void> Function(MotifServer server);

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

  /// A client which already proved this exact route with [prevalidatedPing].
  /// Ownership transfers to the connection pool through
  /// [takePreconnectedClient]. Keeping it lets the first real RPC reuse the
  /// probe's TLS/HTTP connection instead of handshaking again.
  http.Client? _preconnectedClient;
  final PingInfo? prevalidatedPing;

  TransportReady({
    required this.target,
    required this.proxy,
    this.certPin,
    http.Client? preconnectedClient,
    this.prevalidatedPing,
  }) : assert(
         (preconnectedClient == null) == (prevalidatedPing == null),
         'a preconnected client and its validated ping transfer together',
       ),
       _preconnectedClient = preconnectedClient;

  http.Client? takePreconnectedClient() {
    final client = _preconnectedClient;
    _preconnectedClient = null;
    return client;
  }

  void dispose() {
    _preconnectedClient?.close();
    _preconnectedClient = null;
  }
}

class TransportBlocked extends TransportResolution {
  final ConnectionBlocker blocker;

  const TransportBlocked(this.blocker);
}

class TransportResolver {
  static const Duration _directProbeTimeout = Duration(seconds: 3);
  static const Duration _relayProbeTimeout = Duration(seconds: 8);
  static const Duration _relayFallbackDelay = Duration(milliseconds: 200);
  static const Duration _initialPromotionBudget = Duration(milliseconds: 300);

  final PlatformServices platform;
  final SshForwarderFactory _sshForwarderFactory;
  final SshAutoInitializer _sshAutoInitializer;
  final WslAutoInitializer _wslAutoInitializer;
  final bool _wslSupported;
  final RzvRouteCache _rzvRouteCache;
  final http.Client Function(ProxySettings proxy, Uint8List? certPin)
  _httpClientFactory;

  /// Live loopback forwarders for `rendezvous` servers, keyed by server id.
  /// Started lazily on [resolve] and torn down by [stopForwarder] when the
  /// owning connection disconnects or the server is removed.
  final Map<String, RzvForwarder> _rzvForwarders = {};

  /// Live loopback forwarders for `ssh` servers, keyed by server id.
  final Map<String, SshForwarderHandle> _sshForwarders = {};

  /// Last runtime transport failure for a server, keyed by server id. Validation
  /// errors are computed from the server config; this map is only for failures
  /// discovered while starting a relay/tunnel.
  final ObservableMap<String, TransportViewState> _transportFailures =
      ObservableMap();

  TransportResolver(
    this.platform, {
    SshForwarderFactory? sshForwarderFactory,
    SshAutoInitializer? sshAutoInitializer,
    WslAutoInitializer? wslAutoInitializer,
    bool? wslSupported,
    RzvRouteCache? rzvRouteCache,
    http.Client Function(ProxySettings proxy, Uint8List? certPin)?
    httpClientFactory,
  }) : _sshForwarderFactory = sshForwarderFactory ?? _defaultSshForwarder,
       _sshAutoInitializer = sshAutoInitializer ?? _defaultSshAutoInitialize,
       _wslAutoInitializer = wslAutoInitializer ?? _defaultWslAutoInitialize,
       _rzvRouteCache = rzvRouteCache ?? RzvRouteCache.memory(),
       _httpClientFactory = httpClientFactory ?? _defaultHttpClientFactory,
       _wslSupported =
           wslSupported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows);

  static http.Client _defaultHttpClientFactory(
    ProxySettings proxy,
    Uint8List? certPin,
  ) => makeHttpClient(proxy, certPin: certPin);

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

  static Future<void> _defaultWslAutoInitialize(MotifServer server) =>
      WslBootstrapper(server: server).ensureMotifd();

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
      ServerKind.wsl =>
        _wslSupported
            ? TransportViewState.wsl(
                server,
                validationMessage: _validateWsl(server),
              )
            : TransportViewState.unavailable(
                kind: ServerKind.wsl,
                statusLabel: 'WSL unavailable',
                message:
                    'WSL servers are available only in the Windows desktop app.',
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
      case ServerKind.wsl:
        return _resolveWsl(server);
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
  /// `/ping`. The in-memory view updates synchronously and the non-sensitive
  /// hint is persisted best-effort for the next process launch. IPv6 candidates
  /// are currently dropped because the direct route does not yet carry a scope
  /// id for link-local addresses.
  bool learnRzvDirect(MotifServer server, PingInfo? ping) {
    if (server.kind != ServerKind.rendezvous) return false;
    final port = ping?.rzvDirectPort;
    final v4 = (ping?.rzvDirectAddrs ?? const <String>[])
        .where((a) => !a.contains(':'))
        .toList(growable: false);
    if (port == null || port <= 0 || v4.isEmpty) {
      // The server explicitly omitted a usable route; discard stale state so a
      // future advertisement is treated as new again.
      _rzvRouteCache.remove(server.id);
      return false;
    }
    final firstTime = _rzvRouteCache.lookup(server) == null;
    _rzvRouteCache.rememberCandidates(server, port: port, addrs: v4);
    return firstTime;
  }

  /// Forget any learned LAN-direct candidates for [serverId], so the next
  /// session starts on the relay again. Call on a deliberate disconnect /
  /// server removal — not on the transient forwarder teardown of an upgrade.
  void forgetRzvDirect(String serverId) {
    _rzvRouteCache.remove(serverId);
  }

  void retainRzvDirect(Set<String> serverIds) =>
      _rzvRouteCache.retain(serverIds);

  /// Probe [addrs] (at [port]) concurrently and resolve to the first that
  /// answers as a motif-server, or `null` if none do within the per-probe
  /// timeout. When [certPin] is set the probe runs over TLS (`https`) pinning
  /// that cert; otherwise plaintext. Never throws.
  Future<_ProbedRoute?> _firstReachableDirect(
    MotifServer server,
    List<String> addrs,
    int port, {
    Uint8List? certPin,
    required String bearer,
    Duration timeout = _directProbeTimeout,
    String reason = 'direct',
  }) {
    if (addrs.isEmpty) return Future.value(null);
    final sw = Stopwatch()..start();
    Log.i(
      '$reason probe begin candidates=${addrs.length} port=$port '
      'tls=${certPin != null}',
      name: 'motif.resume',
    );
    final completer = Completer<_ProbedRoute?>();
    var pending = addrs.length;
    for (final addr in addrs) {
      final target = server.copyWith(
        host: addr,
        port: port,
        scheme: certPin == null ? 'http' : 'https',
        token: bearer,
      );
      _probeTarget(
        target,
        proxy: ProxySettings.none,
        certPin: certPin,
        timeout: timeout,
        routeLabel: '$reason:$addr',
      ).then((route) {
        if (completer.isCompleted) {
          route?.dispose();
          return;
        }
        if (route != null) {
          Log.i(
            '$reason probe hit address=$addr '
            'took=${sw.elapsedMilliseconds}ms',
            name: 'motif.resume',
          );
          completer.complete(route);
        } else if (--pending == 0) {
          Log.i(
            '$reason probe miss candidates=${addrs.length} '
            'took=${sw.elapsedMilliseconds}ms',
            name: 'motif.resume',
          );
          completer.complete(null);
        }
      });
    }
    return completer.future;
  }

  Future<_ProbedRoute?> _probeTarget(
    MotifServer target, {
    required ProxySettings proxy,
    required Uint8List? certPin,
    required Duration timeout,
    required String routeLabel,
  }) async {
    final client = _httpClientFactory(proxy, certPin);
    final sw = Stopwatch()..start();
    try {
      final resp = await client
          .get(
            Uri(
              scheme: target.scheme,
              host: target.host,
              port: target.port,
              path: '/ping',
            ),
          )
          .timeout(timeout);
      if (resp.statusCode != 200) {
        throw RpcException('ping HTTP ${resp.statusCode}');
      }
      final info = PingInfo.fromJson(
        jsonDecode(resp.body) as Map<String, Object?>,
      );
      if (!info.isMotifServer) {
        throw RpcException('Not a motif server at ${target.endpoint}');
      }
      Log.i(
        'route probe ready route=$routeLabel '
        'took=${sw.elapsedMilliseconds}ms',
        name: 'motif.resume',
      );
      return _ProbedRoute(
        target: target,
        proxy: proxy,
        certPin: certPin,
        client: client,
        ping: info,
        label: routeLabel,
      );
    } catch (error) {
      client.close();
      Log.i(
        'route probe failed route=$routeLabel '
        'took=${sw.elapsedMilliseconds}ms error=$error',
        name: 'motif.resume',
      );
      return null;
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
      server,
      server.directHosts,
      server.port,
      certPin: certPin,
      bearer: bearer,
      reason: 'paired-direct',
    );
    if (hit == null) {
      return _recordFailure(
        server,
        statusLabel: 'Direct unreachable',
        message:
            'None of ${server.directHosts.length} advertised address(es) reachable',
      );
    }
    return hit.takeReady();
  }

  /// Bring up (or reuse) a loopback forwarder that pairs with `motifd` through
  /// the relay, then connect to it as if it were a plain local server. The
  /// rest of the stack is unaware of the rendezvous hop.
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
    // psk-derived motifd access bearer, sent on every connection (relay or
    // direct) over its TLS channel.
    final bearer = _authBearer(server.psk);

    try {
      final cached = !kIsWeb && certPin != null
          ? _rzvRouteCache.lookup(server)
          : null;
      final _ProbedRoute route;
      if (cached != null) {
        // Happy-Eyeballs policy: direct gets a small head start, then the relay
        // is dialed in parallel. A stale LAN hint can therefore delay a remote
        // client by at most the stagger, not by the full direct timeout.
        route = await _raceCachedRendezvous(
          server,
          relay: relay,
          token: token,
          certPin: certPin!,
          bearer: bearer,
          hint: cached,
        );
      } else {
        final relayRoute = await _probeRelayRoute(
          server,
          relay: relay,
          token: token,
          certPin: certPin,
          bearer: bearer,
        );
        learnRzvDirect(server, relayRoute.ping);

        // On the first-ever connection the relay response is the only source
        // of LAN candidates. Keep that already healthy relay alive while giving
        // direct a short promotion window. A miss never tears down/rebuilds the
        // relay and never blocks startup for the old three-second timeout.
        final learned = certPin == null ? null : _rzvRouteCache.lookup(server);
        final promoted = learned == null || kIsWeb
            ? null
            : await _firstReachableDirect(
                server,
                learned.orderedAddrs,
                learned.port,
                certPin: certPin,
                bearer: bearer,
                timeout: _initialPromotionBudget,
                reason: 'rzv-initial-direct',
              );
        if (promoted == null) {
          route = relayRoute;
        } else {
          relayRoute.dispose();
          await stopForwarder(server.id);
          _rzvRouteCache.rememberSuccess(server, promoted.target.host);
          route = promoted;
        }
      }

      if (route.label == 'rzv-relay') {
        learnRzvDirect(server, route.ping);
      } else {
        // A direct `/ping` is allowed to omit its own LAN advertisement. Keep
        // the relay-learned candidate set and only move the successful address
        // to the front for the next launch.
        _rzvRouteCache.rememberSuccess(server, route.target.host);
      }
      return route.takeReady();
    } on _RzvForwarderStartException catch (error) {
      await stopForwarder(server.id);
      return _recordFailure(
        server,
        statusLabel: 'Rendezvous failed',
        message: 'Rendezvous forwarder failed to start: ${error.cause}',
      );
    } catch (_) {
      // A failed relay probe must not leave its loopback listener or any
      // half-paired WSS route cached. Forced retries can arrive while the pool
      // has no current generation, so without this cleanup they would keep
      // reusing the failed in-process route until the app restarted.
      await stopForwarder(server.id);
      rethrow;
    }
  }

  Future<_ProbedRoute> _raceCachedRendezvous(
    MotifServer server, {
    required ({String scheme, String host, int port}) relay,
    required Uint8List token,
    required Uint8List certPin,
    required String bearer,
    required RzvRouteHint hint,
  }) async {
    final completer = Completer<_ProbedRoute>();
    Object? relayError;
    var directDone = false;
    var relayDone = false;
    var relayStarted = false;
    Timer? relayTimer;

    void win(_ProbedRoute route) {
      if (completer.isCompleted) {
        route.dispose();
      } else {
        completer.complete(route);
      }
    }

    void maybeFail() {
      if (!completer.isCompleted && directDone && relayDone) {
        completer.completeError(
          relayError ??
              RpcException(
                'Neither cached direct nor rendezvous relay route responded',
              ),
        );
      }
    }

    Future<void> startRelay() async {
      if (relayStarted || completer.isCompleted) return;
      relayStarted = true;
      relayTimer?.cancel();
      try {
        win(
          await _probeRelayRoute(
            server,
            relay: relay,
            token: token,
            certPin: certPin,
            bearer: bearer,
          ),
        );
      } catch (error) {
        relayError = error;
        relayDone = true;
        maybeFail();
      }
    }

    unawaited(
      _firstReachableDirect(
        server,
        hint.orderedAddrs,
        hint.port,
        certPin: certPin,
        bearer: bearer,
        reason: 'rzv-direct',
      ).then((direct) {
        directDone = true;
        if (direct != null) {
          win(direct);
        } else {
          unawaited(startRelay());
          maybeFail();
        }
      }),
    );
    relayTimer = Timer(_relayFallbackDelay, () => unawaited(startRelay()));

    final winner = await completer.future;
    relayTimer.cancel();
    if (winner.label.startsWith('rzv-direct')) {
      // If the delayed relay already started, stopping the forwarder cancels it;
      // its completion handler disposes any late route without replacing the
      // direct winner.
      await stopForwarder(server.id);
    }
    return winner;
  }

  Future<_ProbedRoute> _probeRelayRoute(
    MotifServer server, {
    required ({String scheme, String host, int port}) relay,
    required Uint8List token,
    required Uint8List? certPin,
    required String bearer,
  }) async {
    final target = await _ensureRendezvousTarget(
      server,
      relay: relay,
      token: token,
      certPin: certPin,
      bearer: bearer,
    );
    final route = await _probeTarget(
      target,
      proxy: ProxySettings.none,
      certPin: certPin,
      timeout: _relayProbeTimeout,
      routeLabel: 'rzv-relay',
    );
    if (route == null) {
      throw RpcException('Rendezvous relay route did not answer as motifd');
    }
    return route;
  }

  Future<MotifServer> _ensureRendezvousTarget(
    MotifServer server, {
    required ({String scheme, String host, int port}) relay,
    required Uint8List token,
    required Uint8List? certPin,
    required String bearer,
  }) async {
    var fwd = _rzvForwarders[server.id];
    if (fwd != null &&
        (fwd.relayHost != relay.host ||
            fwd.relayPort != relay.port ||
            fwd.relayScheme != relay.scheme ||
            !listEquals(fwd.token, token))) {
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
    } catch (error) {
      throw _RzvForwarderStartException(error);
    }
    return server.copyWith(
      host: '127.0.0.1',
      port: fwd.port,
      scheme: certPin == null ? 'http' : 'https',
      token: bearer,
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

  /// Ensure motifd is running inside WSL, then connect through Windows/WSL
  /// localhost forwarding. Unlike SSH, no explicit tunnel is needed.
  Future<TransportResolution> _resolveWsl(MotifServer server) async {
    try {
      await _wslAutoInitializer(server);
    } catch (e) {
      return _recordFailure(
        server,
        statusLabel: 'WSL init failed',
        message: _wslInitFailureMessage(e),
      );
    }

    return TransportReady(
      target: server.copyWith(host: '127.0.0.1', scheme: 'http', token: ''),
      proxy: ProxySettings.none,
    );
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

  static String? _validateWsl(MotifServer server) {
    if (server.port <= 0 || server.port > 65535) {
      return 'WSL server has an invalid motifd port';
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

  static String _wslInitFailureMessage(Object error) =>
      error is WslBootstrapException
      ? error.toString()
      : 'WSL initialize failed: $error';
}

final class _ProbedRoute {
  _ProbedRoute({
    required this.target,
    required this.proxy,
    required this.certPin,
    required this.client,
    required this.ping,
    required this.label,
  });

  final MotifServer target;
  final ProxySettings proxy;
  final Uint8List? certPin;
  final http.Client client;
  final PingInfo ping;
  final String label;
  bool _transferred = false;

  TransportReady takeReady() {
    if (_transferred) throw StateError('probed route already transferred');
    _transferred = true;
    return TransportReady(
      target: target,
      proxy: proxy,
      certPin: certPin,
      preconnectedClient: client,
      prevalidatedPing: ping,
    );
  }

  void dispose() {
    if (_transferred) return;
    _transferred = true;
    client.close();
  }
}

final class _RzvForwarderStartException implements Exception {
  const _RzvForwarderStartException(this.cause);

  final Object cause;
}
