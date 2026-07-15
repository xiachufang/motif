/// Loopback forwarder for the rendezvous WSS connect side.
///
/// Each local byte-stream connection gets one outer WebSocket. Binary messages
/// carry the existing end-to-end TLS stream; native WebSocket PING/PONG keeps
/// the relay path alive.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../log/log.dart';
import 'rzv_protocol.dart';

class RzvForwarder {
  RzvForwarder({
    required this.relayHost,
    required this.relayPort,
    required Uint8List token,
    this.relayScheme = 'wss',
    this.pairTimeout = const Duration(seconds: 30),
    this.dialTimeout = const Duration(seconds: 10),
  }) : token = Uint8List.fromList(token),
       assert(
         token.length == RzvProtocol.tokenLength,
         'rzv token must be ${RzvProtocol.tokenLength} bytes',
       );

  final String relayHost;
  final int relayPort;
  final String relayScheme;
  final Uint8List token;
  final Duration pairTimeout;
  final Duration dialTimeout;

  ServerSocket? _server;
  final Set<_Conn> _conns = {};

  int get port {
    final s = _server;
    if (s == null) throw StateError('RzvForwarder not started');
    return s.port;
  }

  bool get isRunning => _server != null;

  Future<int> start() async {
    if (_server != null) return _server!.port;
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen(
      _onLocal,
      onError: (Object e) =>
          Log.w('rzv forwarder accept error: $e', name: 'motif.rzv'),
    );
    Log.i(
      'rzv forwarder 127.0.0.1:${s.port} -> '
      '$relayScheme://$relayHost:$relayPort/v2/connect',
      name: 'motif.rzv',
    );
    return s.port;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close();
    for (final c in _conns.toList()) {
      c.destroy();
    }
    _conns.clear();
  }

  Future<void> _onLocal(Socket local) async {
    final uri = Uri(
      scheme: relayScheme,
      host: relayHost,
      port: relayPort,
      path: '/v2/connect',
    );
    WebSocket relay;
    try {
      relay = await WebSocket.connect(uri.toString()).timeout(dialTimeout);
      relay.pingInterval = const Duration(seconds: 15);
    } catch (e) {
      Log.w('rzv: WSS dial failed: $e', name: 'motif.rzv');
      local.destroy();
      return;
    }

    final conn = _Conn(local, relay);
    _conns.add(conn);
    try {
      relay.add(RzvProtocol.buildHello(token));
    } catch (e) {
      Log.w('rzv: write HELLO failed: $e', name: 'motif.rzv');
      conn.destroy();
      _conns.remove(conn);
      return;
    }

    final pairTimer = Timer(pairTimeout, () {
      if (!conn.paired) {
        Log.w('rzv: no PAIRED within $pairTimeout', name: 'motif.rzv');
        conn.destroy();
        _conns.remove(conn);
      }
    });
    final pending = BytesBuilder(copy: false);

    local.listen(
      (chunk) {
        if (conn.paired) {
          conn.writeRelay(chunk);
        } else {
          pending.add(chunk);
        }
      },
      onError: (Object _) {
        pairTimer.cancel();
        conn.destroy();
        _conns.remove(conn);
      },
      onDone: () {
        pairTimer.cancel();
        conn.closeRelay();
        _conns.remove(conn);
      },
      cancelOnError: true,
    );

    relay.listen(
      (message) {
        if (message is! List<int>) {
          conn.destroy();
          return;
        }
        if (!conn.paired) {
          if (message.length == 1 && message[0] == RzvProtocol.ctrlPaired) {
            conn.paired = true;
            pairTimer.cancel();
            if (pending.isNotEmpty) conn.writeRelay(pending.takeBytes());
          } else {
            Log.w('rzv: unexpected frame before PAIRED', name: 'motif.rzv');
            conn.destroy();
          }
          return;
        }
        conn.writeLocal(message);
      },
      onError: (Object _) {
        pairTimer.cancel();
        conn.destroy();
        _conns.remove(conn);
      },
      onDone: () {
        pairTimer.cancel();
        if (!conn.paired) {
          Log.w('rzv: relay closed before PAIRED', name: 'motif.rzv');
        }
        conn.destroy();
        _conns.remove(conn);
      },
      cancelOnError: true,
    );
  }
}

class _Conn {
  _Conn(this.local, this.relay);

  final Socket local;
  final WebSocket relay;
  bool paired = false;
  bool _dead = false;

  void writeLocal(List<int> data) {
    if (_dead) return;
    try {
      local.add(data);
    } catch (_) {
      destroy();
    }
  }

  void writeRelay(List<int> data) {
    if (_dead) return;
    try {
      relay.add(data);
    } catch (_) {
      destroy();
    }
  }

  void closeRelay() {
    if (_dead) return;
    unawaited(relay.close());
  }

  void destroy() {
    if (_dead) return;
    _dead = true;
    try {
      local.destroy();
    } catch (_) {}
    unawaited(relay.close());
  }
}
