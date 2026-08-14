import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/net/rpc_session_transport.dart';
import 'package:motif/motif/state/server/server_connection_pool.dart';
import 'package:motif/motif/state/server/transport_resolver.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'home readiness is reused by Session and Codex without another resolve or ping',
    () async {
      const server = MotifServer(
        id: 'shared',
        name: 'Shared',
        host: 'motif.test',
        port: 7788,
        token: 'secret',
      );
      var resolveCalls = 0;
      var pingCalls = 0;
      final requests = <http.BaseRequest>[];
      final socketUris = <Uri>[];
      final sockets = <_FakeWebSocket>[];
      final client = _RecordingClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/ping':
            pingCalls++;
            return _response(
              jsonEncode(const {'service': 'motif-server', 'version': 'test'}),
            );
          case '/rpc/session.attach':
            return _response(
              jsonEncode(const {'client_id': 'client', 'last_seq': 7}),
              headers: const {'x-motif-session': 'attachment-1'},
            );
          default:
            return _response('{}');
        }
      });
      final pool = DefaultServerConnectionPool(
        serverId: server.id,
        serverProvider: () => server,
        resolveRoute: (profile) async {
          resolveCalls++;
          return TransportReady(target: profile, proxy: ProxySettings.none);
        },
        stopForwarder: (_) async {},
        forgetLearnedRoute: (_) {},
        httpClientFactory: (_, _) => client,
        webSocketConnector:
            ({
              required uri,
              required headers,
              required proxy,
              required certPin,
            }) {
              socketUris.add(uri);
              final socket = _FakeWebSocket();
              sockets.add(socket);
              return socket;
            },
        healthTtl: const Duration(minutes: 1),
      );
      addTearDown(pool.dispose);

      final home = pool.acquire(
        ownerId: 'home',
        ownerKind: ConnectionOwnerKind.serverHome,
      );
      await home.ensureReady();

      final session = RpcSessionTransport(
        pool.acquire(
          ownerId: 'session',
          ownerKind: ConnectionOwnerKind.session,
        ),
      );
      addTearDown(session.close);
      await session.call('session.attach', const {
        'name': 'dev',
        'last_seq': 7,
      });
      await session.call('pty.list');

      final codex = RpcCodexTransport(pool);
      addTearDown(codex.close);
      await codex.connect();

      expect(resolveCalls, 1);
      expect(pingCalls, 1);
      expect(client.closeCount, 0);
      expect(
        requests
            .singleWhere((request) => request.url.path == '/rpc/pty.list')
            .headers['X-Motif-Session'],
        'attachment-1',
      );
      expect(
        requests
            .singleWhere((request) => request.url.path == '/rpc/codex.start')
            .headers
            .containsKey('X-Motif-Session'),
        isFalse,
      );
      expect(socketUris.map((uri) => uri.path), ['/events', '/codex']);
      expect(socketUris.first.queryParameters, {
        'since': '7',
        'session': 'attachment-1',
        'token': 'secret',
      });
      expect(sockets, hasLength(2));
    },
  );
}

http.StreamedResponse _response(
  String body, {
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.value(Uint8List.fromList(utf8.encode(body))),
  200,
  headers: headers,
);

final class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);

  @override
  void close() => closeCount++;
}

final class _FakeWebSocket
    with StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _FakeWebSocket() {
    sink = _FakeSink(() async {
      if (!_incoming.isClosed) await _incoming.close();
    });
  }

  final StreamController<Object?> _incoming = StreamController<Object?>();

  @override
  Stream<Object?> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink;

  @override
  Future<void> get ready => Future<void>.value();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;
}

final class _FakeSink implements WebSocketSink {
  _FakeSink(this.onClose);

  final Future<void> Function() onClose;
  final Completer<void> _done = Completer<void>();

  @override
  void add(Object? event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await onClose();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
