import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/remote_port_forwarder.dart';
import 'package:motif/motif/net/rpc_session_transport.dart';
import 'package:motif/motif/net/server_web_link_proxy.dart';
import 'package:motif/motif/net/web_link.dart';
import 'package:motif/motif/state/server/server_connection_pool.dart';

import 'support/test_connection_pool.dart';

void main() {
  for (final sessionId in <String?>['sid-1', null]) {
    test('RemotePortForwarder tunnels HTTP (session=$sessionId)', () async {
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
            if (ascii
                .decode(pending, allowInvalid: true)
                .contains('\r\n\r\n')) {
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

      WebLinkProxy? proxy;
      Uri localUrl;
      if (sessionId == null) {
        proxy = await openServerWebLinkProxy(
          pool,
          Uri.parse('http://192.168.1.8:3000/a%2Fb?q=x%26y#section'),
        );
        addTearDown(proxy.close);
        localUrl = proxy.url;
        expect(pool.snapshot.activeOwners, 2);
        expect(localUrl.path, '/a%2Fb');
        expect(localUrl.query, 'q=x%26y');
        expect(localUrl.fragment, 'section');
      } else {
        final forwarder = await RemotePortForwarder.start(
          rpc: rpc,
          sessionId: sessionId,
          remotePort: 3000,
        );
        addTearDown(forwarder.stop);
        localUrl = forwarder.localUrl;
      }

      final http = HttpClient();
      addTearDown(http.close);
      final req = await http.getUrl(localUrl);
      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();

      expect(resp.statusCode, 200);
      expect(body, 'ok');
      await serverDone.future.timeout(const Duration(seconds: 2));
      expect(tcpRequests.single.path, '/tcp');
      expect(tcpRequests.single.queryParameters['session'], sessionId);
      expect(
        tcpRequests.single.queryParameters['host'],
        sessionId == null ? '192.168.1.8' : '127.0.0.1',
      );
      expect(tcpRequests.single.queryParameters['port'], '3000');
      expect(tcpRequests.single.queryParameters['token'], 'secret');
      if (proxy != null) {
        await proxy.close();
        await proxy.close();
        expect(pool.snapshot.activeOwners, 1);
        await expectLater(
          Socket.connect(localUrl.host, localUrl.port),
          throwsA(isA<SocketException>()),
        );
      }
    });
  }
}
