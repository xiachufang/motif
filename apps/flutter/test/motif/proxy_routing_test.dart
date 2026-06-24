@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/net/rpc_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Validates that [RpcClient] tunnels through a **SOCKS5** proxy (the form the
/// tsnet loopback uses) by standing up a minimal local SOCKS5 server that
/// forwards to the live motifd, then `ping`-ing through it. Self-contained
/// (no tailnet). Skips if no motifd on 127.0.0.1:7777.
void main() {
  test(
    'RpcClient.ping reaches motifd through a SOCKS5 proxy',
    () async {
      final probe = RpcClient()
        ..connect(host: '127.0.0.1', port: 7777, token: '');
      try {
        await probe.ping();
      } catch (_) {
        await probe.close();
        markTestSkipped('no motifd on 127.0.0.1:7777');
        return;
      }
      await probe.close();

      final proxy = await _MinimalSocks5.start();
      try {
        final rpc = RpcClient()
          ..connect(
            host: '127.0.0.1',
            port: 7777,
            token: '',
            proxy: ProxySettings(proxyHost: '127.0.0.1', proxyPort: proxy.port),
          );
        final ping = await rpc.ping();
        expect(
          ping.isMotifServer,
          isTrue,
          reason: 'ping should reach motifd via the SOCKS5 proxy',
        );
        expect(proxy.connections, greaterThan(0));
        await rpc.close();
      } finally {
        await proxy.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

/// Minimal SOCKS5 (no-auth, CONNECT) proxy that relays to the requested host.
class _MinimalSocks5 {
  final ServerSocket _server;
  int connections = 0;
  _MinimalSocks5(this._server) {
    _server.listen(_handle);
  }
  int get port => _server.port;

  static Future<_MinimalSocks5> start() async =>
      _MinimalSocks5(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> close() => _server.close();

  Future<void> _handle(Socket client) async {
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
      final r = _ByteReader(client);
      final ver = await r.read(1);
      if (ver[0] != 0x05) return client.destroy();
      final n = (await r.read(1))[0];
      await r.read(n);
      client.add([0x05, 0x00]); // no auth

      final hdr = await r.read(4); // VER CMD RSV ATYP
      if (hdr[1] != 0x01) return client.destroy(); // CONNECT only
      final String host;
      switch (hdr[3]) {
        case 0x01:
          host = (await r.read(4)).join('.');
        case 0x03:
          host = String.fromCharCodes(await r.read((await r.read(1))[0]));
        default:
          return client.destroy();
      }
      final pb = await r.read(2);
      final port = (pb[0] << 8) | pb[1];

      final up = await Socket.connect(host, port);
      connections++;
      client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]); // success
      up.listen(
        client.add,
        onDone: client.destroy,
        onError: (_) => client.destroy(),
      );
      await r.pumpTo(up);
      await up.close();
    } catch (_) {
      client.destroy();
    }
  }
}

class _ByteReader {
  final StreamIterator<Uint8List> _it;
  final BytesBuilder _buf = BytesBuilder();
  _ByteReader(Stream<Uint8List> s) : _it = StreamIterator(s);

  Future<Uint8List> read(int n) async {
    while (_buf.length < n) {
      if (!await _it.moveNext()) throw const SocketException('eof');
      _buf.add(_it.current);
    }
    final all = _buf.takeBytes();
    final out = Uint8List.sublistView(all, 0, n);
    _buf.add(Uint8List.sublistView(all, n));
    return out;
  }

  Future<void> pumpTo(Socket dst) async {
    final rem = _buf.takeBytes();
    if (rem.isNotEmpty) dst.add(rem);
    while (await _it.moveNext()) {
      dst.add(_it.current);
    }
  }
}
