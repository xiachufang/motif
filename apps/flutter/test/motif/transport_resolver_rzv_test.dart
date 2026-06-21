import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rzv/rzv_protocol.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/transport_resolver.dart';

void main() {
  final pskBytes = Uint8List.fromList(List.generate(32, (i) => i + 3));
  final pskB64 = base64Url.encode(pskBytes).replaceAll('=', '');

  late _FakeRelay relay;
  late TransportResolver resolver;

  setUp(() {
    resolver = TransportResolver(PlatformServices.defaults());
  });

  tearDown(() async {
    await relay.stop();
  });

  test(
    'resolves to a loopback target that reaches motifd via the relay',
    () async {
      relay = await _FakeRelay.start();
      final s = MotifServer(
        id: 'rzv-1',
        name: 'studio',
        host: 'studio',
        kind: ServerKind.rendezvous,
        relay: '127.0.0.1:${relay.port}',
        psk: pskB64,
      );

      final res = await resolver.resolve(s);
      expect(res, isA<TransportReady>());
      final ready = res as TransportReady;
      expect(ready.target.host, '127.0.0.1');
      expect(ready.target.scheme, 'http');
      expect(ready.target.port, greaterThan(0));

      // The loopback target really tunnels through the relay: connect to it and
      // confirm the fake relay echoes (i.e. the forwarder paired and spliced).
      final client = await Socket.connect('127.0.0.1', ready.target.port);
      final payload = Uint8List.fromList('via-resolver'.codeUnits);
      final echo = _collect(client, payload.length);
      client.add(payload);
      await client.flush();
      expect(await echo.timeout(const Duration(seconds: 5)), payload);
      expect(relay.hellos, hasLength(1));
      expect(
        RzvProtocol.parseHello(relay.hellos.single).token,
        RzvProtocol.deriveToken(pskBytes),
        reason:
            'wire token is HKDF-derived from the pairing secret, not the raw psk',
      );

      await client.close();
      await resolver.stopForwarder('rzv-1');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'reuses one forwarder across repeated resolves',
    () async {
      relay = await _FakeRelay.start();
      final s = MotifServer(
        id: 'rzv-1',
        name: 'studio',
        host: 'studio',
        kind: ServerKind.rendezvous,
        relay: '127.0.0.1:${relay.port}',
        psk: pskB64,
      );
      final a = await resolver.resolve(s) as TransportReady;
      final b = await resolver.resolve(s) as TransportReady;
      expect(a.target.port, b.target.port, reason: 'same forwarder reused');
      await resolver.stopForwarder('rzv-1');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'with a cert pin in the QR resolves to https + 32-byte certPin',
    () async {
      relay = await _FakeRelay.start();
      final pin = base64Url
          .encode(Uint8List.fromList(List.generate(32, (i) => i + 1)))
          .replaceAll('=', '');
      final s = MotifServer(
        id: 'rzv-pin',
        name: 'studio',
        host: 'studio',
        kind: ServerKind.rendezvous,
        relay: '127.0.0.1:${relay.port}',
        psk: pskB64,
        pubKey: pin,
      );
      final res = await resolver.resolve(s) as TransportReady;
      expect(res.target.scheme, 'https');
      expect(res.certPin, isNotNull);
      expect(res.certPin!.length, 32);
      await resolver.stopForwarder('rzv-pin');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'blocks cleanly on a bad relay address or pairing secret',
    () async {
      relay = await _FakeRelay.start();
      final badRelay = MotifServer(
        id: 'x',
        name: 'x',
        host: 'x',
        kind: ServerKind.rendezvous,
        relay: 'no-port',
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
        relay: '127.0.0.1:${relay.port}',
        psk: 'too-short',
      );
      final badPskResult = await resolver.resolve(badPsk);
      expect(badPskResult, isA<TransportBlocked>());
      expect(
        (badPskResult as TransportBlocked).blocker.message,
        contains('pairing secret'),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  // sha256 of the shared self-signed test cert → the pin (`pk`); and the psk
  // bearer the client must send.
  final pin = Uint8List.fromList(sha256.convert(base64.decode(_certDerB64)).bytes);
  final pinB64 = base64Url.encode(pin).replaceAll('=', '');
  final expectedBearer =
      base64Url.encode(RzvProtocol.deriveAuthBearer(pskBytes)).replaceAll('=', '');

  group('LAN-direct upgrade (TLS-pinned)', () {
    MotifServer rzvServer(int relayPort, {String id = 'rzv-d'}) => MotifServer(
      id: id,
      name: 'studio',
      host: 'studio',
      kind: ServerKind.rendezvous,
      relay: '127.0.0.1:$relayPort',
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

    test('probes a learned candidate and upgrades to a TLS-pinned direct target',
        () async {
      relay = await _FakeRelay.start();
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
      expect(relay.hellos, isEmpty, reason: 'relay never dialed on a direct hit');

      await motifd.close(force: true);
      await resolver.stopForwarder(s.id);
    });

    test('falls back to the relay when no candidate answers as motifd',
        () async {
      relay = await _FakeRelay.start();
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
      expect(res.target.token, expectedBearer, reason: 'relay path carries bearer too');

      // The forwarder dials the relay lazily, on the first local connection —
      // drive one through to confirm we really fell back to the relay tunnel.
      final client = await Socket.connect('127.0.0.1', res.target.port);
      final payload = Uint8List.fromList('fallback'.codeUnits);
      final echo = _collect(client, payload.length);
      client.add(payload);
      await client.flush();
      expect(await echo.timeout(const Duration(seconds: 5)), payload);
      expect(relay.hellos, hasLength(1), reason: 'forwarder dialed the relay');

      await client.close();
      await impostor.close(force: true);
      await resolver.stopForwarder(s.id);
    });
  });

  group('direct server (TLS-pinned candidate probe)', () {
    MotifServer directServer(int port, List<String> hosts, {String id = 'd1'}) =>
        MotifServer(
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
Future<HttpServer> _fakeMotifd({String service = 'motif-server'}) async {
  final ctx = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(_certPem))
    ..usePrivateKeyBytes(utf8.encode(_keyPem));
  final srv = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
  srv.listen((req) async {
    if (req.uri.path == '/ping') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'service': service, 'version': 't'}));
    } else {
      req.response.statusCode = HttpStatus.notFound;
    }
    await req.response.close();
  });
  return srv;
}

Future<Uint8List> _collect(Socket sock, int n) {
  final out = BytesBuilder();
  final c = Completer<Uint8List>();
  late StreamSubscription<Uint8List> sub;
  sub = sock.listen(
    (chunk) {
      out.add(chunk);
      if (out.length >= n && !c.isCompleted) {
        c.complete(Uint8List.sublistView(out.toBytes(), 0, n));
        sub.cancel();
      }
    },
    onError: (Object e) {
      if (!c.isCompleted) c.completeError(e);
    },
  );
  return c.future;
}

/// Minimal in-process relay + echo peer: reads HELLO, sends PAIRED, echoes.
class _FakeRelay {
  _FakeRelay(this._server);
  final ServerSocket _server;
  final List<Uint8List> hellos = [];
  final List<Socket> _socks = [];

  int get port => _server.port;

  static Future<_FakeRelay> start() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _FakeRelay(s);
    s.listen(relay._onConn);
    return relay;
  }

  void _onConn(Socket sock) {
    _socks.add(sock);
    final buf = <int>[];
    var paired = false;
    sock.listen((chunk) {
      if (paired) {
        sock.add(chunk);
        return;
      }
      buf.addAll(chunk);
      if (buf.length >= RzvProtocol.helloLength) {
        hellos.add(Uint8List.fromList(buf.sublist(0, RzvProtocol.helloLength)));
        buf.removeRange(0, RzvProtocol.helloLength);
        sock.add(const [RzvProtocol.ctrlPaired]);
        paired = true;
        if (buf.isNotEmpty) {
          sock.add(Uint8List.fromList(buf));
          buf.clear();
        }
      }
    }, onError: (_) {});
  }

  Future<void> stop() async {
    for (final s in _socks) {
      s.destroy();
    }
    await _server.close();
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
