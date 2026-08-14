import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/remote_port_forwarder.dart';
import 'package:motif/motif/net/rpc_session_transport.dart';
import 'package:motif/motif/state/server/server_connection_pool.dart';

import 'support/test_connection_pool.dart';

void main() {
  test('RemotePortForwarder tunnels local HTTP over /tcp websocket', () async {
    final tcpRequests = <Uri>[];
    final wsServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(wsServer.close);

    final serverDone = Completer<void>();
    wsServer.listen((request) async {
      if (request.method == 'GET' && request.uri.path == '/ping') {
        request.response.write(
          jsonEncode({'service': 'motif-server', 'version': 'test'}),
        );
        await request.response.close();
        return;
      }
      tcpRequests.add(request.uri);
      final ws = await WebSocketTransformer.upgrade(request);
      final pending = <int>[];
      await for (final msg in ws) {
        if (msg is List<int>) {
          pending.addAll(msg);
          if (ascii.decode(pending, allowInvalid: true).contains('\r\n\r\n')) {
            ws.add(
              ascii.encode(
                'HTTP/1.1 200 OK\r\n'
                'Content-Length: 2\r\n'
                'Connection: close\r\n'
                '\r\n'
                'ok',
              ),
            );
            await ws.close();
            serverDone.complete();
            break;
          }
        }
      }
    });

    final pool = fixedRouteConnectionPool(
      MotifServer(
        id: 'remote-port-test',
        name: 'Remote port test',
        host: '127.0.0.1',
        port: wsServer.port,
        token: 'secret',
      ),
    );
    addTearDown(pool.dispose);
    final rpc = RpcSessionTransport(
      pool.acquire(
        ownerId: 'session:remote-port-test',
        ownerKind: ConnectionOwnerKind.session,
      ),
    );
    addTearDown(rpc.close);

    final forwarder = await RemotePortForwarder.start(
      rpc: rpc,
      sessionId: 'sid-1',
      remotePort: 3000,
    );
    addTearDown(forwarder.stop);

    final http = HttpClient();
    addTearDown(http.close);
    final req = await http.getUrl(forwarder.localUrl);
    final resp = await req.close();
    final body = await utf8.decoder.bind(resp).join();

    expect(resp.statusCode, 200);
    expect(body, 'ok');
    await serverDone.future.timeout(const Duration(seconds: 2));
    expect(tcpRequests.single.path, '/tcp');
    expect(tcpRequests.single.queryParameters['session'], 'sid-1');
    expect(tcpRequests.single.queryParameters['host'], '127.0.0.1');
    expect(tcpRequests.single.queryParameters['port'], '3000');
    expect(tcpRequests.single.queryParameters['token'], 'secret');
  });
}
