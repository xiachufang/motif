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
        token: token,
      );
      await fwd.start();

      final client = await Socket.connect('127.0.0.1', fwd.port);
      final payload = Uint8List.fromList(utf8Bytes('hello rendezvous'));
      final echo = _collect(client, payload.length);
      client.add(payload);
      await client.flush();

      expect(await echo, payload, reason: 'relay should echo through the pipe');

      // The forwarder presented a well-formed connect-role HELLO with our token.
      expect(relay.hellos, hasLength(1));
      final parsed = RzvProtocol.parseHello(relay.hellos.single);
      expect(parsed.role, RzvProtocol.roleConnect);
      expect(parsed.token, token);

      await client.close();
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'answers PING with PONG before pairing',
    () async {
      relay = await _FakeRelay.start(sendPing: true);
      fwd = RzvForwarder(
        relayHost: '127.0.0.1',
        relayPort: relay.port,
        token: token,
      );
      await fwd.start();

      final client = await Socket.connect('127.0.0.1', fwd.port);
      final payload = Uint8List.fromList(utf8Bytes('after-ping'));
      final echo = _collect(client, payload.length);
      client.add(payload);
      await client.flush();

      expect(await echo, payload);
      expect(relay.pongSeen, isTrue, reason: 'forwarder must answer PING');

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

/// In-process stand-in for the rzv relay + motifd echo peer. Reads the
/// forwarder's HELLO, optionally exchanges PING/PONG, sends PAIRED, then echoes
/// everything (acting as the paired motifd). Self-contained; [stop] tears it
/// down so no listener leaks past the test.
class _FakeRelay {
  _FakeRelay(this._server, {this.sendPing = false, this.silent = false});

  final ServerSocket _server;
  final bool sendPing;
  final bool silent;
  final List<Uint8List> hellos = [];
  bool pongSeen = false;
  final List<Socket> _socks = [];

  int get port => _server.port;

  static Future<_FakeRelay> start({
    bool sendPing = false,
    bool silent = false,
  }) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _FakeRelay(s, sendPing: sendPing, silent: silent);
    s.listen(relay._onConn);
    return relay;
  }

  void _onConn(Socket sock) {
    _socks.add(sock);
    final buf = <int>[];
    var state = 0; // 0=await hello, 1=await pong, 2=echo
    sock.listen(
      (chunk) {
        buf.addAll(chunk);
        while (true) {
          if (state == 0) {
            if (buf.length < RzvProtocol.helloLength) break;
            hellos.add(
              Uint8List.fromList(buf.sublist(0, RzvProtocol.helloLength)),
            );
            buf.removeRange(0, RzvProtocol.helloLength);
            if (silent) {
              state = 3; // park forever, never pair
              break;
            }
            if (sendPing) {
              sock.add(const [RzvProtocol.ctrlPing]);
              state = 1;
            } else {
              sock.add(const [RzvProtocol.ctrlPaired]);
              state = 2;
            }
          } else if (state == 1) {
            if (buf.isEmpty) break;
            final b = buf.removeAt(0);
            pongSeen = b == RzvProtocol.ctrlPong;
            sock.add(const [RzvProtocol.ctrlPaired]);
            state = 2;
          } else if (state == 2) {
            if (buf.isEmpty) break;
            sock.add(Uint8List.fromList(buf));
            buf.clear();
          } else {
            break; // state 3: silent
          }
        }
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  Future<void> stop() async {
    for (final s in _socks) {
      s.destroy();
    }
    await _server.close();
  }
}
