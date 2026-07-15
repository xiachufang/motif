import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/rzv/rzv_forwarder.dart';
import 'package:motif/motif/net/rzv/rzv_protocol.dart';

void main() {
  final token = Uint8List.fromList(List.generate(32, (i) => i * 2 % 256));

  late _FakeRelay relay;
  late RzvForwarder fwd;

  tearDown(() async {
    await fwd.stop();
    await relay.stop();
  });

  test(
    'pairs and pipes bytes end-to-end through the relay',
    () async {
      relay = await _FakeRelay.start();
      fwd = RzvForwarder(
        relayHost: '127.0.0.1',
        relayPort: relay.port,
        relayScheme: 'ws',
        token: token,
      );
      await fwd.start();

      final client = await Socket.connect('127.0.0.1', fwd.port);
      final payload = Uint8List.fromList(utf8Bytes('hello rendezvous'));
      final echo = _collect(client, payload.length);
      client.add(payload);
      await client.flush();

      expect(await echo, payload, reason: 'relay should echo through the pipe');

      // The forwarder presented a well-formed binary HELLO with our token.
      expect(relay.hellos, hasLength(1));
      final parsed = RzvProtocol.parseHello(relay.hellos.single);
      expect(parsed, token);

      await client.close();
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'stays parked through native WebSocket PING/PONG',
    () async {
      relay = await _FakeRelay.start(
        pairDelay: const Duration(milliseconds: 150),
        pingInterval: const Duration(milliseconds: 50),
      );
      fwd = RzvForwarder(
        relayHost: '127.0.0.1',
        relayPort: relay.port,
        relayScheme: 'ws',
        token: token,
      );
      await fwd.start();

      final client = await Socket.connect('127.0.0.1', fwd.port);
      final payload = Uint8List.fromList(utf8Bytes('after-ping'));
      final echo = _collect(client, payload.length);
      client.add(payload);
      await client.flush();

      expect(await echo, payload);

      await client.close();
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'tears down local connection when relay never pairs',
    () async {
      relay = await _FakeRelay.start(silent: true); // never sends PAIRED
      fwd = RzvForwarder(
        relayHost: '127.0.0.1',
        relayPort: relay.port,
        relayScheme: 'ws',
        token: token,
        pairTimeout: const Duration(milliseconds: 300),
      );
      await fwd.start();

      final client = await Socket.connect('127.0.0.1', fwd.port);
      // Local socket should be closed by the forwarder after the pair timeout.
      final done = Completer<void>();
      client.listen(
        (_) {},
        onDone: done.complete,
        onError: (_) => done.complete(),
      );
      await done.future.timeout(const Duration(seconds: 5));
      await client.close();
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

List<int> utf8Bytes(String s) => s.codeUnits;

/// Collect exactly [n] bytes from [sock].
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
    onDone: () {
      if (!c.isCompleted) {
        c.completeError(
          StateError('socket closed after ${out.length}/$n bytes'),
        );
      }
    },
  );
  return c.future;
}

/// In-process WebSocket relay + motifd echo peer.
class _FakeRelay {
  _FakeRelay(
    this._server, {
    this.silent = false,
    this.pairDelay = Duration.zero,
    this.pingInterval,
  });

  final HttpServer _server;
  final bool silent;
  final Duration pairDelay;
  final Duration? pingInterval;
  final List<Uint8List> hellos = [];
  final List<WebSocket> _sockets = [];

  int get port => _server.port;

  static Future<_FakeRelay> start({
    bool silent = false,
    Duration pairDelay = Duration.zero,
    Duration? pingInterval,
  }) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _FakeRelay(
      s,
      silent: silent,
      pairDelay: pairDelay,
      pingInterval: pingInterval,
    );
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
    socket.pingInterval = pingInterval;
    var paired = false;
    socket.listen((message) async {
      if (message is! List<int>) return;
      if (!paired) {
        hellos.add(Uint8List.fromList(message));
        if (silent) return;
        if (pairDelay > Duration.zero) await Future<void>.delayed(pairDelay);
        socket.add(const [RzvProtocol.ctrlPaired]);
        paired = true;
      } else {
        socket.add(message);
      }
    }, onError: (_) {});
  }

  Future<void> stop() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}
