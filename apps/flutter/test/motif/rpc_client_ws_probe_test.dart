import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motif/motif/net/rpc_client.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  tearDown(() {
    RpcClient.debugHttpClientFactory = null;
    RpcClient.debugWebSocketFactory = null;
  });

  test('probes events and PTYs and reopens only a failed PTY stream', () async {
    RpcClient.debugHttpClientFactory = () => MockClient((request) async {
      expect(request.url.path, '/rpc/session.attach');
      return http.Response(
        jsonEncode({'client_id': 'client-1', 'last_seq': 0}),
        200,
        headers: {'x-motif-session': 'sid-1'},
      );
    });

    final sockets = <_FakeWebSocketChannel>[];
    RpcClient.debugWebSocketFactory = (url) {
      final path = Uri.parse(url).path;
      late final _FakeWebSocketChannel socket;
      socket = _FakeWebSocketChannel((message) {
        if (message is! String || !socket.respondToProbe) return;
        final frame = jsonDecode(message);
        if (frame is Map && frame['type'] == 'motif.probe.v1') {
          scheduleMicrotask(
            () => socket.addIncoming(
              jsonEncode({'type': 'motif.probe_ack.v1', 'id': frame['id']}),
            ),
          );
        }
      });
      socket.pathKind = path == '/events'
          ? _PathKind.events
          : path.startsWith('/pty/')
          ? _PathKind.pty
          : _PathKind.unknown;
      sockets.add(socket);
      if (path.startsWith('/pty/')) {
        scheduleMicrotask(
          () => socket.addIncoming(
            jsonEncode({
              'since': 0,
              'pty_frame': 'v1',
              'pty_compress': 'zlib',
              'replay_bytes': 0,
            }),
          ),
        );
      }
      return socket;
    };

    final rpc = RpcClient()
      ..connect(host: 'localhost', port: 7777, token: 'token');
    final emittedEvents = <MotifEvent>[];
    final eventSub = rpc.events.listen(emittedEvents.add);
    await rpc.call('session.attach', {'name': 'dev'});
    await rpc.activatePty('pty-1');
    await Future<void>.delayed(Duration.zero);

    final healthy = await rpc.probeSessionStreams(
      timeout: const Duration(milliseconds: 50),
    );
    expect(healthy.eventsAlive, isTrue);
    expect(healthy.failedPtyIds, isEmpty);
    expect(
      emittedEvents,
      isEmpty,
      reason: 'probe ACK must not leak as an event',
    );

    final originalPty = sockets.singleWhere((s) => s.pathKind == _PathKind.pty);
    originalPty.respondToProbe = false;
    final partial = await rpc.probeSessionStreams(
      timeout: const Duration(milliseconds: 20),
    );
    expect(partial.eventsAlive, isTrue);
    expect(partial.failedPtyIds, {'pty-1'});

    await rpc.reopenPtyStreams(partial.failedPtyIds);
    expect(sockets.where((s) => s.pathKind == _PathKind.pty), hasLength(2));

    await rpc.close();
    await eventSub.cancel();
  });
}

enum _PathKind { unknown, events, pty }

final class _FakeWebSocketChannel
    with StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _FakeWebSocketChannel(this._onSend) {
    sink = _FakeWebSocketSink(_onSend, _incoming.close);
  }

  final void Function(Object?) _onSend;
  final StreamController<Object?> _incoming = StreamController<Object?>();
  bool respondToProbe = true;
  _PathKind pathKind = _PathKind.unknown;

  void addIncoming(Object? message) {
    if (!_incoming.isClosed) _incoming.add(message);
  }

  @override
  Stream<Object?> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

final class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._onAdd, this._onClose);

  final void Function(Object?) _onAdd;
  final Future<void> Function() _onClose;
  final Completer<void> _done = Completer<void>();

  @override
  void add(Object? event) => _onAdd(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await _onClose();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
