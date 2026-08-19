import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rzv/rzv_protocol.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/server/transport_resolver.dart';

void main() {
  final pskBytes = Uint8List.fromList(List.generate(32, (i) => i + 3));
  final pskB64 = base64Url.encode(pskBytes).replaceAll('=', '');

  late _FakeRelay relay;
  late TransportResolver resolver;
  final motifds = <HttpServer>[];

  setUp(() {
    resolver = TransportResolver(PlatformServices.defaults());
  });

  tearDown(() async {
    await relay.stop();
    for (final motifd in motifds) {
      await motifd.close(force: true);
    }
    motifds.clear();
  });

  test(
    'resolves to a loopback target that reaches motifd via the relay',
    () async {
      final motifd = await _fakeMotifd(secure: false);
      motifds.add(motifd);
      relay = await _FakeRelay.start(targetPort: motifd.port);
      final s = MotifServer(
        id: 'rzv-1',
        name: 'studio',
        host: 'studio',
        kind: ServerKind.rendezvous,
        relay: 'ws://127.0.0.1:${relay.port}',
        psk: pskB64,
      );

      final res = await resolver.resolve(s);
      expect(res, isA<TransportReady>());
      final ready = res as TransportReady;
      expect(ready.target.host, '127.0.0.1');
      expect(ready.target.scheme, 'http');
      expect(ready.target.port, greaterThan(0));

      expect(ready.prevalidatedPing?.isMotifServer, isTrue);
      expect(relay.hellos, hasLength(1));
      expect(
        RzvProtocol.parseHello(relay.hellos.single),
        RzvProtocol.deriveToken(pskBytes),
        reason:
            'wire token is HKDF-derived from the pairing secret, not the raw psk',
      );

      ready.dispose();
      await resolver.stopForwarder('rzv-1');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('reuses one forwarder across repeated resolves', () async {
    final motifd = await _fakeMotifd(secure: false);
    motifds.add(motifd);
    relay = await _FakeRelay.start(targetPort: motifd.port);
    final s = MotifServer(
      id: 'rzv-1',
      name: 'studio',
      host: 'studio',
      kind: ServerKind.rendezvous,
      relay: 'ws://127.0.0.1:${relay.port}',
      psk: pskB64,
    );
    final a = await resolver.resolve(s) as TransportReady;
    final b = await resolver.resolve(s) as TransportReady;
    expect(a.target.port, b.target.port, reason: 'same forwarder reused');
    a.dispose();
    b.dispose();
    await resolver.stopForwarder('rzv-1');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('failed relay probe is discarded before retry', () async {
    relay = await _FakeRelay.start();
    final probedPorts = <int>[];
    var probes = 0;
    resolver = TransportResolver(
      PlatformServices.defaults(),
      httpClientFactory: (_, _) => MockClient((request) async {
        probedPorts.add(request.url.port);
        probes++;
        return http.Response(
          jsonEncode({
            'service': probes == 1 ? 'not-motifd' : 'motif-server',
            'version': 'test',
          }),
          200,
        );
      }),
    );
    final s = MotifServer(
      id: 'rzv-retry',
      name: 'studio',
      host: 'studio',
      kind: ServerKind.rendezvous,
      relay: 'ws://127.0.0.1:${relay.port}',
      psk: pskB64,
    );

    await expectLater(
      resolver.resolve(s),
      throwsA(
        isA<Exception>().having(
          (error) => '$error',
          'message',
          contains('did not answer as motifd'),
        ),
      ),
    );
    final ready = await resolver.resolve(s) as TransportReady;

    expect(probedPorts, hasLength(2));
    expect(
      probedPorts[1],
      isNot(probedPorts[0]),
      reason: 'retry must use a newly-created loopback forwarder',
    );
    ready.dispose();
    await resolver.stopForwarder(s.id);
  });

  test('pairing secret change replaces the cached forwarder', () async {
    final motifd = await _fakeMotifd(secure: false);
    motifds.add(motifd);
    relay = await _FakeRelay.start(targetPort: motifd.port);
    final first = MotifServer(
      id: 'rzv-repaired',
      name: 'studio',
      host: 'studio',
      kind: ServerKind.rendezvous,
      relay: 'ws://127.0.0.1:${relay.port}',
      psk: pskB64,
    );
    final nextPsk = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    final second = first.copyWith(
      psk: base64Url.encode(nextPsk).replaceAll('=', ''),
    );

    final firstReady = await resolver.resolve(first) as TransportReady;
    firstReady.dispose();
    final secondReady = await resolver.resolve(second) as TransportReady;

    expect(relay.hellos, hasLength(2));
    expect(
      RzvProtocol.parseHello(relay.hellos.last),
      RzvProtocol.deriveToken(nextPsk),
    );
    secondReady.dispose();
    await resolver.stopForwarder(first.id);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'with a cert pin in the QR resolves to https + 32-byte certPin',
    () async {
      final motifd = await _fakeMotifd();
      motifds.add(motifd);
      relay = await _FakeRelay.start(targetPort: motifd.port);
      final pin = base64Url
          .encode(sha256.convert(base64.decode(_certDerB64)).bytes)
          .replaceAll('=', '');
      final s = MotifServer(
        id: 'rzv-pin',
        name: 'studio',
        host: 'studio',
        kind: ServerKind.rendezvous,
        relay: 'ws://127.0.0.1:${relay.port}',
        psk: pskB64,
        pubKey: pin,
      );
      final res = await resolver.resolve(s) as TransportReady;
      expect(res.target.scheme, 'https');
      expect(res.certPin, isNotNull);
      expect(res.certPin!.length, 32);
      res.dispose();
      await resolver.stopForwarder('rzv-pin');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('blocks cleanly on a bad relay address or pairing secret', () async {
    relay = await _FakeRelay.start();
    final badRelay = MotifServer(
      id: 'x',
      name: 'x',
      host: 'x',
      kind: ServerKind.rendezvous,
      relay: 'https://not-a-websocket-relay.example',
      psk: pskB64,
    );
    final badRelayResult = await resolver.resolve(badRelay);
    expect(badRelayResult, isA<TransportBlocked>());
    expect(
      (badRelayResult as TransportBlocked).blocker.message,
      contains('relay address'),
    );

    final badPsk = MotifServer(
      id: 'y',
      name: 'y',
      host: 'y',
      kind: ServerKind.rendezvous,
      relay: 'ws://127.0.0.1:${relay.port}',
      psk: 'too-short',
    );
    final badPskResult = await resolver.resolve(badPsk);
    expect(badPskResult, isA<TransportBlocked>());
    expect(
      (badPskResult as TransportBlocked).blocker.message,
      contains('pairing secret'),
    );
  }, timeout: const Timeout(Duration(seconds: 15)));

  // sha256 of the shared self-signed test cert → the pin (`pk`); and the psk
  // bearer the client must send.
  final pin = Uint8List.fromList(
    sha256.convert(base64.decode(_certDerB64)).bytes,
  );
  final pinB64 = base64Url.encode(pin).replaceAll('=', '');
  final expectedBearer = base64Url
      .encode(RzvProtocol.deriveAuthBearer(pskBytes))
      .replaceAll('=', '');

  group('LAN-direct upgrade (TLS-pinned)', () {
    MotifServer rzvServer(int relayPort, {String id = 'rzv-d'}) => MotifServer(
      id: id,
      name: 'studio',
      host: 'studio',
      kind: ServerKind.rendezvous,
      relay: 'ws://127.0.0.1:$relayPort',
      psk: pskB64,
      pubKey: pinB64,
    );

    test('learnRzvDirect fires once, then stays quiet', () async {
      relay = await _FakeRelay.start();
      final s = rzvServer(relay.port);
      PingInfo ping(List<String> addrs, int? port) => PingInfo(
        service: 'motif-server',
        version: 't',
        rzvDirectPort: port,
        rzvDirectAddrs: addrs,
      );

      // First time candidates appear → true (cue an upgrade reconnect).
      expect(resolver.learnRzvDirect(s, ping(['192.168.1.9'], 7777)), isTrue);
      // Refreshing the same/again → false (no reconnect loop).
      expect(resolver.learnRzvDirect(s, ping(['192.168.1.9'], 7777)), isFalse);

      // No usable candidates → false, and stale state is dropped so the next
      // appearance fires again.
      expect(resolver.learnRzvDirect(s, ping(const [], null)), isFalse);
      expect(resolver.learnRzvDirect(s, ping(['192.168.1.9'], 7777)), isTrue);

      // IPv6-only candidates are ignored (LAN-direct is IPv4).
      resolver.forgetRzvDirect(s.id);
      expect(resolver.learnRzvDirect(s, ping(['fd00::1'], 7777)), isFalse);
    });

    test(
      'first relay ping promotes a reachable direct route without redialing relay',
      () async {
        var relayPings = 0;
        var directPings = 0;
        final directMotifd = await _fakeMotifd(onPing: () => directPings++);
        motifds.add(directMotifd);
        final relayedMotifd = await _fakeMotifd(
          rzvDirectPort: directMotifd.port,
          rzvDirectAddrs: const ['127.0.0.1'],
          onPing: () => relayPings++,
        );
        motifds.add(relayedMotifd);
        relay = await _FakeRelay.start(targetPort: relayedMotifd.port);
        final s = rzvServer(relay.port, id: 'rzv-first-direct');

        final res = await resolver.resolve(s) as TransportReady;

        expect(res.target.port, directMotifd.port);
        expect(relayPings, 1);
        expect(directPings, 1);
        expect(
          relay.hellos,
          hasLength(1),
          reason: 'the healthy relay is retained until direct wins',
        );
        res.dispose();
        await resolver.stopForwarder(s.id);
      },
    );

    test(
      'first unreachable direct hint keeps the already-probed relay',
      () async {
        final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final unreachablePort = unused.port;
        await unused.close();
        var relayPings = 0;
        final relayedMotifd = await _fakeMotifd(
          rzvDirectPort: unreachablePort,
          rzvDirectAddrs: const ['127.0.0.1'],
          onPing: () => relayPings++,
        );
        motifds.add(relayedMotifd);
        relay = await _FakeRelay.start(targetPort: relayedMotifd.port);
        final s = rzvServer(relay.port, id: 'rzv-first-fallback');

        final res = await resolver.resolve(s) as TransportReady;

        expect(res.target.port, isNot(unreachablePort));
        expect(res.prevalidatedPing?.isMotifServer, isTrue);
        expect(relayPings, 1);
        expect(
          relay.hellos,
          hasLength(1),
          reason: 'a direct miss must not rebuild the relay tunnel',
        );
        res.dispose();
        await resolver.stopForwarder(s.id);
      },
    );

    test(
      'probes a learned candidate and upgrades to a TLS-pinned direct target',
      () async {
        final relayedMotifd = await _fakeMotifd();
        motifds.add(relayedMotifd);
        relay = await _FakeRelay.start(targetPort: relayedMotifd.port);
        final motifd = await _fakeMotifd();
        final s = rzvServer(relay.port);

        resolver.learnRzvDirect(
          s,
          PingInfo(
            service: 'motif-server',
            version: 't',
            rzvDirectPort: motifd.port,
            rzvDirectAddrs: const ['127.0.0.1'],
          ),
        );

        final res = await resolver.resolve(s) as TransportReady;
        expect(res.target.host, '127.0.0.1');
        expect(res.target.port, motifd.port, reason: 'dials the direct port');
        expect(res.target.scheme, 'https');
        expect(res.target.token, expectedBearer, reason: 'psk-derived bearer');
        expect(res.certPin, isNotNull);
        expect(res.certPin!.length, 32);
        expect(
          relay.hellos,
          isEmpty,
          reason: 'relay never dialed on a direct hit',
        );

        await motifd.close(force: true);
        res.dispose();
        await resolver.stopForwarder(s.id);
      },
    );

    test(
      'falls back to the relay when no candidate answers as motifd',
      () async {
        final relayedMotifd = await _fakeMotifd();
        motifds.add(relayedMotifd);
        relay = await _FakeRelay.start(targetPort: relayedMotifd.port);
        // Pinned TLS but the wrong service tag → probe rejects it.
        final impostor = await _fakeMotifd(service: 'something-else');
        final s = rzvServer(relay.port);

        resolver.learnRzvDirect(
          s,
          PingInfo(
            service: 'motif-server',
            version: 't',
            rzvDirectPort: impostor.port,
            rzvDirectAddrs: const ['127.0.0.1'],
          ),
        );

        final res = await resolver.resolve(s) as TransportReady;
        // Relay path: loopback forwarder port, not the (rejected) direct port.
        expect(res.target.host, '127.0.0.1');
        expect(res.target.port, isNot(impostor.port));
        expect(
          res.target.token,
          expectedBearer,
          reason: 'relay path carries bearer too',
        );

        expect(res.prevalidatedPing?.isMotifServer, isTrue);
        expect(
          relay.hellos,
          hasLength(1),
          reason: 'forwarder dialed the relay',
        );

        res.dispose();
        await impostor.close(force: true);
        await resolver.stopForwarder(s.id);
      },
    );
  });

  group('direct server (TLS-pinned candidate probe)', () {
    MotifServer directServer(
      int port,
      List<String> hosts, {
      String id = 'd1',
    }) => MotifServer(
      id: id,
      name: 'box',
      host: hosts.first,
      port: port,
      scheme: 'https',
      kind: ServerKind.direct,
      psk: pskB64,
      pubKey: pinB64,
      directHosts: hosts,
    );

    test('probes directHosts and connects to the reachable one', () async {
      final motifd = await _fakeMotifd();
      final s = directServer(motifd.port, const ['127.0.0.1']);

      final res = await resolver.resolve(s) as TransportReady;
      expect(res.target.host, '127.0.0.1');
      expect(res.target.scheme, 'https');
      expect(res.target.token, expectedBearer);
      expect(res.certPin!.length, 32);

      await motifd.close(force: true);
    });

    test(
      'allows public direct probes to take longer than LAN latency',
      () async {
        final motifd = await _fakeMotifd(
          delay: const Duration(milliseconds: 900),
        );
        final s = directServer(motifd.port, const ['127.0.0.1']);

        final res = await resolver.resolve(s) as TransportReady;
        expect(res.target.host, '127.0.0.1');
        expect(res.target.scheme, 'https');
        expect(res.target.token, expectedBearer);

        await motifd.close(force: true);
      },
    );

    test('blocks when no advertised host is reachable', () async {
      final impostor = await _fakeMotifd(service: 'nope');
      final s = directServer(impostor.port, const ['127.0.0.1']);

      final res = await resolver.resolve(s);
      expect(res, isA<TransportBlocked>());

      await impostor.close(force: true);
    });
  });
}

/// Minimal motifd stand-in over TLS (the shared self-signed cert below):
/// answers `GET /ping` with the given `service` tag.
Future<HttpServer> _fakeMotifd({
  String service = 'motif-server',
  Duration delay = Duration.zero,
  bool secure = true,
  int? rzvDirectPort,
  List<String> rzvDirectAddrs = const [],
  void Function()? onPing,
}) async {
  final HttpServer srv;
  if (secure) {
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(_certPem))
      ..usePrivateKeyBytes(utf8.encode(_keyPem));
    srv = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
  } else {
    srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  }
  srv.listen((req) async {
    if (req.uri.path == '/ping') {
      onPing?.call();
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'service': service,
          'version': 't',
          'rzv_direct_port': ?rzvDirectPort,
          if (rzvDirectAddrs.isNotEmpty) 'rzv_direct_addrs': rzvDirectAddrs,
        }),
      );
    } else {
      req.response.statusCode = HttpStatus.notFound;
    }
    await req.response.close();
  });
  return srv;
}

/// Minimal in-process WebSocket relay. With [targetPort] it pipes the paired
/// byte stream to a motifd stand-in; otherwise it echoes for low-level tests.
class _FakeRelay {
  _FakeRelay(this._server, this.targetPort);
  final HttpServer _server;
  final int? targetPort;
  final List<Uint8List> hellos = [];
  final List<WebSocket> _sockets = [];
  final List<Socket> _peers = [];

  int get port => _server.port;

  static Future<_FakeRelay> start({int? targetPort}) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _FakeRelay(s, targetPort);
    s.listen(relay._onRequest);
    return relay;
  }

  Future<void> _onRequest(HttpRequest request) async {
    if (request.uri.path != '/v2/connect' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    var paired = false;
    Socket? peer;
    socket.listen((message) async {
      if (message is! List<int>) return;
      if (paired) {
        final target = peer;
        if (target == null) {
          socket.add(message);
        } else {
          target.add(message);
          await target.flush();
        }
        return;
      }
      hellos.add(Uint8List.fromList(message));
      final target = targetPort;
      if (target != null) {
        peer = await Socket.connect(InternetAddress.loopbackIPv4, target);
        _peers.add(peer!);
        peer!.listen(
          socket.add,
          onError: (_) => socket.close(),
          onDone: () => socket.close(),
        );
      }
      socket.add(const [RzvProtocol.ctrlPaired]);
      paired = true;
    }, onError: (_) {});
  }

  Future<void> stop() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    for (final peer in _peers) {
      peer.destroy();
    }
    await _server.close(force: true);
  }
}

// Shared self-signed test cert (CN=motif-rzv), mirroring rzv_cert_pin_test —
// `_fakeMotifd` serves it and `sha256(cert.der)` is the pin the client checks.
const _certPem = '''
-----BEGIN CERTIFICATE-----
MIIBGDCBvgIJAN3cKs11oLe8MAoGCCqGSM49BAMCMBQxEjAQBgNVBAMMCW1vdGlm
LXJ6djAeFw0yNjA2MTQwMjAyMTdaFw0zNjA2MTEwMjAyMTdaMBQxEjAQBgNVBAMM
CW1vdGlmLXJ6djBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLnr4uPTJuGzjFkr
lpMXEw72hbT+hl2vzRl5kpbGrboCWZFkPULEPI7Iybbblej3eiWnyxEto8ECoA/7
TwcyLq4wCgYIKoZIzj0EAwIDSQAwRgIhAJ49Kv+WGepl6xRkUkD5rtt3LninNhil
I4uoajUuGocyAiEAkbyhMYabjUmYNk2jzBu9LFnXb1PaljrFckXqRksw1do=
-----END CERTIFICATE-----
''';

const _keyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgLb4jGWtyrLJ/hy55
LsPL6WemFjte/4Vtq6xmQMhaFHmhRANCAAS56+Lj0ybhs4xZK5aTFxMO9oW0/oZd
r80ZeZKWxq26AlmRZD1CxDyOyMm225Xo93olp8sRLaPBAqAP+08HMi6u
-----END PRIVATE KEY-----
''';

const _certDerB64 =
    'MIIBGDCBvgIJAN3cKs11oLe8MAoGCCqGSM49BAMCMBQxEjAQBgNVBAMMCW1vdGlmLXJ6djAeFw0yNjA2MTQwMjAyMTdaFw0zNjA2MTEwMjAyMTdaMBQxEjAQBgNVBAMMCW1vdGlmLXJ6djBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLnr4uPTJuGzjFkrlpMXEw72hbT+hl2vzRl5kpbGrboCWZFkPULEPI7Iybbblej3eiWnyxEto8ECoA/7TwcyLq4wCgYIKoZIzj0EAwIDSQAwRgIhAJ49Kv+WGepl6xRkUkD5rtt3LninNhilI4uoajUuGocyAiEAkbyhMYabjUmYNk2jzBu9LFnXb1PaljrFckXqRksw1do=';
