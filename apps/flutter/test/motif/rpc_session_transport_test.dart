import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/net/rpc_session_transport.dart';
import 'package:motif/motif/state/server/server_connection_pool.dart';
import 'package:motif/motif/state/server/transport_resolver.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  tearDown(() {
    _httpClientFactory = null;
    _webSocketFactory = null;
  });

  test('probes events and PTYs and reopens only a failed PTY stream', () async {
    _httpClientFactory = () => MockClient((request) async {
      expect(request.url.path, '/rpc/session.attach');
      return http.Response(
        jsonEncode({'client_id': 'client-1', 'last_seq': 0}),
        200,
        headers: {'x-motif-session': 'sid-1'},
      );
    });

    final sockets = <_FakeWebSocketChannel>[];
    _webSocketFactory = (url) {
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

    final rpc = _newRpc();
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

  test(
    'reopens all session streams with the existing attachment and cursors',
    () async {
      var attachCalls = 0;
      final validationSessionHeaders = <String?>[];
      _httpClientFactory = () => MockClient((request) async {
        if (request.url.path == '/rpc/session.attach') {
          attachCalls++;
          return http.Response(
            jsonEncode({'client_id': 'client-1', 'last_seq': 0}),
            200,
            headers: {'x-motif-session': 'sid-1'},
          );
        }
        if (request.url.path == '/rpc/pty.list') {
          validationSessionHeaders.add(request.headers['x-motif-session']);
          return http.Response(jsonEncode({'ptys': <Object?>[]}), 200);
        }
        return http.Response('', 404);
      });

      final sockets = <_FakeWebSocketChannel>[];
      _webSocketFactory = (url) {
        final uri = Uri.parse(url);
        late final _FakeWebSocketChannel socket;
        socket =
            _FakeWebSocketChannel((message) {
                if (message is! String || !socket.respondToProbe) return;
                final frame = jsonDecode(message);
                if (frame is Map && frame['type'] == 'motif.probe.v1') {
                  scheduleMicrotask(
                    () => socket.addIncoming(
                      jsonEncode({
                        'type': 'motif.probe_ack.v1',
                        'id': frame['id'],
                      }),
                    ),
                  );
                }
              })
              ..uri = uri
              ..pathKind = uri.path == '/events'
                  ? _PathKind.events
                  : uri.path.startsWith('/pty/')
                  ? _PathKind.pty
                  : _PathKind.unknown;
        sockets.add(socket);
        if (socket.pathKind == _PathKind.pty) {
          scheduleMicrotask(
            () => socket.addIncoming(
              jsonEncode({
                'since': 11,
                'pty_frame': 'v1',
                'pty_compress': 'zlib',
                'replay_bytes': 0,
              }),
            ),
          );
        }
        return socket;
      };

      final rpc = _newRpc();
      final emittedEvents = <MotifEvent>[];
      var eventsDone = false;
      final eventSub = rpc.events.listen(
        emittedEvents.add,
        onDone: () => eventsDone = true,
      );
      await rpc.call('session.attach', {'name': 'dev'});
      await rpc.activatePty('pty-1');
      await Future<void>.delayed(Duration.zero);

      final eventsSocket = sockets.singleWhere(
        (socket) => socket.pathKind == _PathKind.events,
      );
      eventsSocket.respondToProbe = false;
      final failedProbe = await rpc.probeSessionStreams(
        timeout: const Duration(milliseconds: 20),
      );
      expect(failedProbe.eventsAlive, isFalse);

      await rpc.reopenSessionStreams(eventSequence: 23);

      expect(attachCalls, 1);
      expect(validationSessionHeaders, ['sid-1']);
      expect(rpc.sessionId, 'sid-1');
      final eventSockets = sockets
          .where((socket) => socket.pathKind == _PathKind.events)
          .toList();
      final ptySockets = sockets
          .where((socket) => socket.pathKind == _PathKind.pty)
          .toList();
      expect(eventSockets, hasLength(2));
      expect(ptySockets, hasLength(2));
      expect(eventSockets.last.uri.queryParameters['session'], 'sid-1');
      expect(eventSockets.last.uri.queryParameters['since'], '23');
      expect(ptySockets.last.uri.queryParameters['session'], 'sid-1');
      expect(ptySockets.last.uri.queryParameters['since'], '11');
      expect(eventsDone, isFalse);

      eventSockets.last.addIncoming(
        jsonEncode({
          'method': 'view.active_changed',
          'params': {'view_id': null, 'seq': 24},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(emittedEvents.map((event) => event.method), [
        'view.active_changed',
      ]);

      await rpc.close();
      await eventSub.cancel();
    },
  );

  test('an events socket failure leaves the attachment reusable', () async {
    _httpClientFactory = () => MockClient((request) async {
      if (request.url.path == '/rpc/session.attach') {
        return http.Response(
          jsonEncode({'client_id': 'client-1', 'last_seq': 0}),
          200,
          headers: {'x-motif-session': 'sid-1'},
        );
      }
      if (request.url.path == '/rpc/pty.list') {
        return http.Response(jsonEncode({'ptys': <Object?>[]}), 200);
      }
      return http.Response('', 404);
    });
    final sockets = <_FakeWebSocketChannel>[];
    _webSocketFactory = (url) {
      final socket = _FakeWebSocketChannel((_) {})
        ..uri = Uri.parse(url)
        ..pathKind = Uri.parse(url).path == '/events'
            ? _PathKind.events
            : _PathKind.unknown;
      sockets.add(socket);
      return socket;
    };

    final rpc = _newRpc();
    var eventsDone = false;
    var failureCount = 0;
    final eventSub = rpc.events.listen((_) {}, onDone: () => eventsDone = true);
    final failureSub = rpc.sessionStreamFailures.listen((_) => failureCount++);
    await rpc.call('session.attach', {'name': 'dev'});

    await sockets.single.closeIncoming();
    await Future<void>.delayed(Duration.zero);
    expect(failureCount, 1);
    expect(eventsDone, isFalse);
    expect(rpc.sessionId, 'sid-1');

    await rpc.reopenSessionStreams(eventSequence: 9);
    expect(sockets, hasLength(2));
    expect(sockets.last.uri.queryParameters['session'], 'sid-1');
    expect(sockets.last.uri.queryParameters['since'], '9');

    await rpc.close();
    await Future.wait([eventSub.cancel(), failureSub.cancel()]);
  });

  test(
    'keeps the old session id when resume validation reports expiry',
    () async {
      _httpClientFactory = () => MockClient((request) async {
        if (request.url.path == '/rpc/session.attach') {
          return http.Response(
            jsonEncode({'client_id': 'client-1', 'last_seq': 0}),
            200,
            headers: {'x-motif-session': 'sid-1'},
          );
        }
        if (request.url.path == '/rpc/pty.list') {
          expect(request.headers['x-motif-session'], 'sid-1');
          return http.Response(
            jsonEncode({
              'code': -32009,
              'message': 'must session.attach first',
            }),
            409,
          );
        }
        return http.Response('', 404);
      });
      _webSocketFactory = (_) => _FakeWebSocketChannel((_) {});

      final rpc = _newRpc();
      await rpc.call('session.attach', {'name': 'dev'});

      await expectLater(
        rpc.reopenSessionStreams(eventSequence: 7),
        throwsA(
          isA<RpcException>().having((error) => error.code, 'code', -32009),
        ),
      );
      expect(rpc.sessionId, 'sid-1');

      await rpc.close();
    },
  );

  test(
    'captureImage sends the tagged target and returns raw PNG bytes',
    () async {
      _httpClientFactory = () => MockClient((request) async {
        if (request.url.path == '/rpc/session.attach') {
          return http.Response(
            jsonEncode({'client_id': 'client-1', 'last_seq': 0}),
            200,
            headers: {'x-motif-session': 'sid-1'},
          );
        }
        expect(request.url.path, '/rpc/capture.take');
        expect(request.headers['authorization'], 'Bearer token');
        expect(request.headers['x-motif-session'], 'sid-1');
        expect(request.headers['accept'], 'image/png');
        expect(jsonDecode(request.body), {
          'target': {'kind': 'window', 'id': 'window:42'},
          'include_cursor': false,
        });
        return http.Response.bytes(
          <int>[0x89, 0x50, 0x4e, 0x47],
          200,
          headers: {'content-type': 'image/png'},
        );
      });
      _webSocketFactory = (_) => _FakeWebSocketChannel((_) {});

      final rpc = _newRpc();
      await rpc.call('session.attach', {'name': 'dev'});
      final bytes = await rpc.captureImage(
        const CaptureTarget(
          kind: CaptureTargetKind.window,
          id: 'window:42',
          name: 'Editor',
          width: 800,
          height: 600,
        ),
      );

      expect(bytes, <int>[0x89, 0x50, 0x4e, 0x47]);
      await rpc.close();
    },
  );
}

http.Client Function()? _httpClientFactory;
WebSocketChannel Function(String url)? _webSocketFactory;

RpcSessionTransport _newRpc() {
  const server = MotifServer(
    id: 'test-server',
    name: 'Test server',
    host: 'localhost',
    port: 7777,
    token: 'token',
  );
  final pool = DefaultServerConnectionPool(
    serverId: server.id,
    serverProvider: () => server,
    resolveRoute: (profile) async =>
        TransportReady(target: profile, proxy: ProxySettings.none),
    stopForwarder: (_) async {},
    forgetLearnedRoute: (_) {},
    learnRoute: (_, _) => false,
    httpClientFactory: (_, _) => _PingClient(_httpClientFactory!.call()),
    webSocketConnector:
        ({required uri, required headers, required proxy, required certPin}) =>
            _webSocketFactory!.call(uri.toString()),
  );
  addTearDown(pool.dispose);
  return RpcSessionTransport(
    pool.acquire(
      ownerId: 'session:test',
      ownerKind: ConnectionOwnerKind.session,
    ),
  );
}

final class _PingClient extends http.BaseClient {
  _PingClient(this.delegate);

  final http.Client delegate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method == 'GET' && request.url.path == '/ping') {
      return Future.value(
        http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({'service': 'motif-server', 'version': 'test'}),
            ),
          ),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
    }
    return delegate.send(request);
  }

  @override
  void close() => delegate.close();
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
  Uri uri = Uri();

  void addIncoming(Object? message) {
    if (!_incoming.isClosed) _incoming.add(message);
  }

  Future<void> closeIncoming() => _incoming.close();

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
