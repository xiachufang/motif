/// Loopback forwarder for SSH-reached motifd servers.
///
/// The rest of the app only knows how to speak HTTP/WebSocket to host:port.
/// This forwarder makes an SSH-only motifd look like a local direct server:
/// bind `127.0.0.1:<ephemeral>`, keep one authenticated SSH connection open,
/// and open a fresh `direct-tcpip` channel for every local HTTP/WS connection.
library;

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../../log/log.dart';
import '../../models/settings.dart';

class SshForwarder {
  SshForwarder({
    required this.sshHost,
    required this.sshPort,
    required this.username,
    required this.authMethod,
    required this.password,
    required this.privateKey,
    required this.privateKeyPassphrase,
    required this.remoteHost,
    required this.remotePort,
    this.connectTimeout = const Duration(seconds: 15),
  });

  final String sshHost;
  final int sshPort;
  final String username;
  final SshAuthMethod authMethod;
  final String password;
  final String privateKey;
  final String privateKeyPassphrase;
  final String remoteHost;
  final int remotePort;
  final Duration connectTimeout;

  ServerSocket? _server;
  SSHClient? _client;
  final Set<_Conn> _conns = {};

  int get port {
    final s = _server;
    if (s == null) throw StateError('SshForwarder not started');
    return s.port;
  }

  bool get isRunning => _server != null && !(_client?.isClosed ?? true);

  bool matches(SshForwarder other) =>
      sshHost == other.sshHost &&
      sshPort == other.sshPort &&
      username == other.username &&
      authMethod == other.authMethod &&
      password == other.password &&
      privateKey == other.privateKey &&
      privateKeyPassphrase == other.privateKeyPassphrase &&
      remoteHost == other.remoteHost &&
      remotePort == other.remotePort;

  Future<int> start() async {
    if (isRunning) return _server!.port;
    await stop();

    final socket = await SSHSocket.connect(
      sshHost,
      sshPort,
      timeout: connectTimeout,
    );
    SSHClient? client;
    try {
      client = SSHClient(
        socket,
        username: username,
        identities: _identities(),
        onPasswordRequest: _usesPassword ? () => password : null,
        onUserInfoRequest: _usesPassword
            ? (dynamic request) {
                final prompts = request.prompts as List<Object?>;
                return List<String>.filled(prompts.length, password);
              }
            : null,
      );
      await client.ping().timeout(connectTimeout);
      _client = client;
    } catch (_) {
      client?.close();
      await socket.close();
      rethrow;
    }

    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen(
      _onLocal,
      onError: (Object e) =>
          Log.w('ssh forwarder accept error: $e', name: 'motif.ssh'),
    );
    Log.i(
      'ssh forwarder 127.0.0.1:${s.port} -> $remoteHost:$remotePort via '
      '$username@$sshHost:$sshPort',
      name: 'motif.ssh',
    );
    unawaited(_watchClientDone(client));
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
    final client = _client;
    _client = null;
    client?.close();
  }

  bool get _usesPassword => authMethod == SshAuthMethod.password;

  List<SSHKeyPair>? _identities() {
    if (authMethod != SshAuthMethod.privateKey) return null;
    final key = privateKey.trim();
    if (key.isEmpty) return null;
    return SSHKeyPair.fromPem(
      key,
      privateKeyPassphrase.isEmpty ? null : privateKeyPassphrase,
    );
  }

  Future<void> _watchClientDone(SSHClient client) async {
    try {
      await client.done;
    } catch (_) {
      // The next reconnect will surface the transport error with context.
    }
    if (identical(_client, client)) {
      await stop();
    }
  }

  Future<void> _onLocal(Socket local) async {
    final client = _client;
    if (client == null || client.isClosed) {
      local.destroy();
      return;
    }

    SSHForwardChannel channel;
    try {
      channel = await client
          .forwardLocal(
            remoteHost,
            remotePort,
            localHost: '127.0.0.1',
            localPort: local.port,
          )
          .timeout(connectTimeout);
    } catch (e) {
      Log.w('ssh: open forward channel failed: $e', name: 'motif.ssh');
      local.destroy();
      return;
    }

    late final _Conn conn;
    conn = _Conn(local, channel, () => _conns.remove(conn));
    _conns.add(conn);
    conn.start();
  }
}

class _Conn {
  _Conn(this.local, this.channel, this.onDone);

  final Socket local;
  final SSHForwardChannel channel;
  final void Function() onDone;

  StreamSubscription<List<int>>? _localSub;
  StreamSubscription<List<int>>? _channelSub;
  bool _dead = false;

  void start() {
    _localSub = local.listen(
      (chunk) {
        if (_dead) return;
        try {
          channel.sink.add(chunk);
        } catch (_) {
          destroy();
        }
      },
      onError: (_) => destroy(),
      onDone: () {
        unawaited(channel.sink.close().catchError((_) {}));
      },
      cancelOnError: true,
    );
    _channelSub = channel.stream.listen(
      (chunk) {
        if (_dead) return;
        try {
          local.add(chunk);
        } catch (_) {
          destroy();
        }
      },
      onError: (_) => destroy(),
      onDone: destroy,
      cancelOnError: true,
    );
    unawaited(channel.done.catchError((_) {}).whenComplete(destroy));
  }

  void destroy() {
    if (_dead) return;
    _dead = true;
    unawaited(_localSub?.cancel());
    unawaited(_channelSub?.cancel());
    try {
      local.destroy();
    } catch (_) {}
    try {
      channel.destroy();
    } catch (_) {}
    onDone();
  }
}
