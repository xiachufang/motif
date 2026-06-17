import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
