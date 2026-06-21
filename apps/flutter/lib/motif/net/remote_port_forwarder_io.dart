import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../log/log.dart';
import 'rpc_client.dart';

class RemotePortForwarder {
  RemotePortForwarder._({
    required this.rpc,
    required this.sessionId,
    required this.remoteHost,
    required this.remotePort,
    required this.localScheme,
    required this._server,
  });

  final RpcClient rpc;
  final String sessionId;
  final String remoteHost;
  final int remotePort;
  final String localScheme;
  final ServerSocket _server;
  final Set<_ForwardedConnection> _connections = {};
  StreamSubscription<Socket>? _acceptSub;
  bool _stopped = false;

  int get localPort => _server.port;

  Uri get localUrl =>
      Uri(scheme: localScheme, host: '127.0.0.1', port: localPort, path: '/');

  static Future<RemotePortForwarder> start({
    required RpcClient rpc,
    required String sessionId,
    String remoteHost = '127.0.0.1',
    required int remotePort,
    int? localPort,
    String localScheme = 'http',
  }) async {
    _validateRemote(remoteHost: remoteHost, remotePort: remotePort);
    if (localScheme != 'http' && localScheme != 'https') {
      throw ArgumentError.value(
        localScheme,
        'localScheme',
        'expected http or https',
      );
    }

    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      localPort ?? 0,
    );
    final forwarder = RemotePortForwarder._(
      rpc: rpc,
      sessionId: sessionId,
      remoteHost: remoteHost,
      remotePort: remotePort,
      localScheme: localScheme,
      server: server,
    );
    forwarder._startAccepting();
    Log.i(
      'remote port forward local=${forwarder.localUrl} -> $remoteHost:$remotePort',
      name: 'motif.port',
    );
    return forwarder;
  }

  void _startAccepting() {
    _acceptSub = _server.listen(
      _onLocal,
      onError: (Object e) =>
          Log.w('remote port accept error: $e', name: 'motif.port'),
      cancelOnError: false,
    );
  }

  void _onLocal(Socket local) {
    if (_stopped) {
      local.destroy();
      return;
    }
    late final _ForwardedConnection conn;
    conn = _ForwardedConnection(
      rpc: rpc,
      sessionId: sessionId,
      remoteHost: remoteHost,
      remotePort: remotePort,
      local: local,
      onDone: () => _connections.remove(conn),
    );
    _connections.add(conn);
    unawaited(conn.start());
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _acceptSub?.cancel();
    _acceptSub = null;
    await _server.close();
    for (final conn in _connections.toList()) {
      conn.destroy();
    }
    _connections.clear();
  }

  static void _validateRemote({
    required String remoteHost,
    required int remotePort,
  }) {
    if (remotePort <= 0 || remotePort > 65535) {
      throw ArgumentError.value(remotePort, 'remotePort', 'expected 1-65535');
    }
    if (remoteHost != '127.0.0.1' &&
        remoteHost != 'localhost' &&
        remoteHost != '::1') {
      throw ArgumentError.value(
        remoteHost,
        'remoteHost',
        'only remote loopback hosts are supported',
      );
    }
  }
}

class _ForwardedConnection {
  _ForwardedConnection({
    required this.rpc,
    required this.sessionId,
    required this.remoteHost,
    required this.remotePort,
    required this.local,
    required this.onDone,
  });

  final RpcClient rpc;
  final String sessionId;
  final String remoteHost;
  final int remotePort;
  final Socket local;
  final void Function() onDone;

  WebSocketChannel? _ws;
  StreamSubscription<List<int>>? _localSub;
  StreamSubscription<Object?>? _wsSub;
  final BytesBuilder _pendingLocalBytes = BytesBuilder(copy: false);
  bool _wsReady = false;
  bool _dead = false;

  Future<void> start() async {
    _localSub = local.listen(
      (chunk) {
        if (_dead) return;
        if (_wsReady) {
          _writeWs(chunk);
        } else {
          _pendingLocalBytes.add(chunk);
        }
      },
      onError: (_) => destroy(),
      onDone: () {
        if (_wsReady) {
          _closeWs();
        } else {
          destroy();
        }
      },
      cancelOnError: true,
    );

    final ws = rpc.openRawWebSocket(
      '/tcp',
      query: {'session': sessionId, 'host': remoteHost, 'port': '$remotePort'},
    );
    _ws = ws;

    try {
      await ws.ready;
    } catch (e, st) {
      Log.w(
        'remote port ws open failed',
        name: 'motif.port',
        error: e,
        stackTrace: st,
      );
      destroy();
      return;
    }
    if (_dead || _ws != ws) {
      unawaited(ws.sink.close().catchError((_) {}));
      return;
    }

    _wsReady = true;
    if (_pendingLocalBytes.isNotEmpty) {
      _writeWs(_pendingLocalBytes.takeBytes());
    }
    _wsSub = ws.stream.listen(
      (msg) {
        if (_dead) return;
        if (msg is List<int>) {
          try {
            local.add(msg);
          } catch (_) {
            destroy();
          }
        }
      },
      onError: (_) => destroy(),
      onDone: destroy,
      cancelOnError: true,
    );
  }

  void _writeWs(List<int> chunk) {
    if (_dead) return;
    try {
      _ws?.sink.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    } catch (_) {
      destroy();
    }
  }

  void destroy() {
    if (_dead) return;
    _dead = true;
    unawaited(_localSub?.cancel());
    unawaited(_wsSub?.cancel());
    try {
      local.destroy();
    } catch (_) {}
    try {
      _closeWs();
    } catch (_) {}
    onDone();
  }

  void _closeWs() {
    final ws = _ws;
    if (ws == null) return;
    unawaited(ws.sink.close().catchError((_) {}));
  }
}
