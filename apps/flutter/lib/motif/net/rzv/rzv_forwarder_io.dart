/// Loopback forwarder for the rendezvous (rzv) connect side.
///
/// Makes a relay-reached `motifd` look like a plain local server to the rest of
/// the client. [start] binds `127.0.0.1:<ephemeral>`; for every inbound local
/// connection it dials the relay, runs the [RzvProtocol] handshake
/// (`HELLO(connect)` → wait for `PAIRED`, answering `PING` with `PONG`), then
/// splices bytes both ways. The existing WebSocket/HTTP transport connects to
/// `http://127.0.0.1:<port>` exactly as it would to a direct server, so
/// `RpcClient` stays transport-agnostic — mirroring how the tailscale path
/// exposes a loopback proxy.
///
/// One local connection ⇒ one relay pairing (per-connection rendezvous). The
/// matching `motifd` keeps a pool of parked `accept`s and re-parks after each
/// pairing; see `docs/rzv-protocol.md`.
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
    this.pairTimeout = const Duration(seconds: 30),
    this.dialTimeout = const Duration(seconds: 10),
  })  : token = Uint8List.fromList(token),
        assert(token.length == RzvProtocol.tokenLength,
            'rzv token must be ${RzvProtocol.tokenLength} bytes');

  final String relayHost;
  final int relayPort;
  final Uint8List token;
  final Duration pairTimeout;
  final Duration dialTimeout;

  ServerSocket? _server;
  final Set<_Conn> _conns = {};

  /// The loopback port the forwarder is listening on. Throws if not started.
  int get port {
    final s = _server;
    if (s == null) throw StateError('RzvForwarder not started');
    return s.port;
  }

  bool get isRunning => _server != null;

  /// Bind the loopback listener and begin accepting. Returns the bound port.
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
      'rzv forwarder 127.0.0.1:${s.port} -> $relayHost:$relayPort',
      name: 'motif.rzv',
    );
    return s.port;
  }

  /// Stop accepting and tear down every in-flight pairing.
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
    Socket relay;
    try {
      relay = await Socket.connect(relayHost, relayPort, timeout: dialTimeout);
    } catch (e) {
      Log.w('rzv: dial relay failed: $e', name: 'motif.rzv');
      local.destroy();
      return;
    }

    final conn = _Conn(local, relay);
    _conns.add(conn);

    try {
      relay.add(RzvProtocol.buildHello(RzvProtocol.roleConnect, token));
      await relay.flush();
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

    // Buffer anything the local side writes (the HTTP/WS upgrade request can
    // arrive the instant it connects to loopback) until the relay reports
    // PAIRED, then flush it through. Writing before PAIRED would feed bytes to
    // the relay while it's still in control-byte mode.
    final pending = BytesBuilder(copy: false);

    local.listen(
      (chunk) {
        if (conn.paired) {
          conn.writeRelay(chunk);
        } else {
          pending.add(chunk);
        }
      },
      onError: (Object e) {
        conn.destroy();
        _conns.remove(conn);
      },
      onDone: () {
        // If we never paired, tear down; once paired the relay onDone will.
        if (!conn.paired) {
          pairTimer.cancel();
          conn.destroy();
          _conns.remove(conn);
        } else {
          conn.closeRelayWrite();
        }
      },
      cancelOnError: true,
    );

    relay.listen(
      (chunk) {
        if (conn.paired) {
          conn.writeLocal(chunk);
          return;
        }
        // Pre-pairing: consume control bytes one at a time until PAIRED.
        for (var i = 0; i < chunk.length; i++) {
          final b = chunk[i];
          if (b == RzvProtocol.ctrlPaired) {
            conn.paired = true;
            pairTimer.cancel();
            if (pending.isNotEmpty) conn.writeRelay(pending.takeBytes());
            final rest = Uint8List.sublistView(chunk, i + 1);
            if (rest.isNotEmpty) conn.writeLocal(rest);
            return;
          } else if (b == RzvProtocol.ctrlPing) {
            conn.writeRelay(Uint8List.fromList(const [RzvProtocol.ctrlPong]));
          }
          // Other pre-pairing bytes are ignored defensively.
        }
      },
      onError: (Object e) {
        pairTimer.cancel();
        conn.destroy();
        _conns.remove(conn);
      },
      onDone: () {
        pairTimer.cancel();
        if (conn.paired) {
          conn.closeLocalWrite();
        } else {
          Log.w('rzv: relay closed before PAIRED', name: 'motif.rzv');
        }
        conn.destroy();
        _conns.remove(conn);
      },
      cancelOnError: true,
    );
  }
}

/// A live local↔relay pairing. Centralises writes so a closed peer can't crash
/// the splice (writing to a destroyed `Socket` throws).
class _Conn {
  _Conn(this.local, this.relay);

  final Socket local;
  final Socket relay;
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

  void closeLocalWrite() {
    try {
      local.destroy();
    } catch (_) {}
  }

  void closeRelayWrite() {
    try {
      relay.destroy();
    } catch (_) {}
  }

  void destroy() {
    if (_dead) return;
    _dead = true;
    try {
      local.destroy();
    } catch (_) {}
    try {
      relay.destroy();
    } catch (_) {}
  }
}
