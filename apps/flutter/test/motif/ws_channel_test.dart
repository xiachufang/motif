import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/ws_channel_io.dart';

void main() {
  for (final scheme in ['ws', 'wss']) {
    test('$scheme handshake has a bounded ready future', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final disconnected = Completer<void>();
      final sockets = <Socket>[];
      final accepts = server.listen((socket) {
        sockets.add(socket);
        socket.listen(
          (_) {},
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
          },
        );
      });
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await accepts.cancel();
        await server.close();
      });
      final channel = connectWebSocket(
        '$scheme://127.0.0.1:${server.port}/ws/codex',
        connectTimeout: const Duration(milliseconds: 100),
      );
      final messages = channel.stream.listen((_) {}, onError: (Object _) {});
      await expectLater(channel.ready, throwsA(isA<TimeoutException>()));
      // Plain HTTP can be cancelled immediately. Dart may retain an in-flight
      // TLS handshake until the peer closes; it must not hold up ready/retry.
      if (scheme == 'ws') {
        await disconnected.future.timeout(const Duration(seconds: 1));
      }
      await messages.cancel();
    });
  }

  test(
    'upgraded WebSocket remains usable after its dial client closes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? peer;
      final accepts = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        peer = socket;
        socket.listen(socket.add);
      });
      addTearDown(() async {
        await peer?.close();
        await accepts.cancel();
        await server.close(force: true);
      });
      final channel = connectWebSocket('ws://127.0.0.1:${server.port}/echo');
      final received = channel.stream.first;
      await channel.ready;
      channel.sink.add('hello');
      expect(await received.timeout(const Duration(seconds: 1)), 'hello');
      await channel.sink.close();
    },
  );
}
