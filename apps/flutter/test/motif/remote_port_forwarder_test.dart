import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/remote_port_forwarder.dart';
import 'package:motif/motif/net/rpc_client.dart';

void main() {
  test('RemotePortForwarder tunnels local HTTP over /tcp websocket', () async {
    final tcpRequests = <Uri>[];
    final wsServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(wsServer.close);

    final serverDone = Completer<void>();
    wsServer.listen((request) async {
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

    final rpc = RpcClient()
      ..connect(host: '127.0.0.1', port: wsServer.port, token: 'secret');
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
