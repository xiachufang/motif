import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/state/server/server_connection_pool.dart';
import 'package:motif/motif/state/server/transport_resolver.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _serverA = MotifServer(
  id: 'server-a',
  name: 'Server A',
  host: 'a.test',
  port: 7788,
  token: 'token-a',
);
const _serverB = MotifServer(
  id: 'server-b',
  name: 'Server B',
  host: 'b.test',
  port: 7789,
  token: 'token-b',
);

void main() {
  test('same-server handles share one HTTP generation', () async {
    final fixture = _PoolFixture(_serverA);
    addTearDown(fixture.dispose);
    final first = fixture.pool.acquire(
      ownerId: 'home',
      ownerKind: ConnectionOwnerKind.serverHome,
    );
    final second = fixture.pool.acquire(
      ownerId: 'codex',
      ownerKind: ConnectionOwnerKind.codex,
    );

    await first.ensureReady();
    await second.rpc('session.list', retry: RpcRetryPolicy.safeOnce);

    expect(fixture.resolveCalls, 1);
    expect(fixture.clients, hasLength(1));
    expect(fixture.clients.single.paths, ['/ping', '/rpc/session.list']);
  });

  test('different servers never share an HTTP client', () async {
    final firstFixture = _PoolFixture(_serverA);
    final secondFixture = _PoolFixture(_serverB);
    addTearDown(firstFixture.dispose);
    addTearDown(secondFixture.dispose);

    await firstFixture.pool
        .acquire(ownerId: 'home-a', ownerKind: ConnectionOwnerKind.serverHome)
        .ensureReady();
    await secondFixture.pool
        .acquire(ownerId: 'home-b', ownerKind: ConnectionOwnerKind.serverHome)
        .ensureReady();

    expect(firstFixture.clients, hasLength(1));
    expect(secondFixture.clients, hasLength(1));
    expect(
      identical(firstFixture.clients.single, secondFixture.clients.single),
      isFalse,
    );
  });

  test('concurrent ensureReady resolves and pings once', () async {
    final gate = Completer<void>();
    final fixture = _PoolFixture(_serverA, resolveGate: gate.future);
    addTearDown(fixture.dispose);
    final first = fixture.pool.acquire(
      ownerId: 'one',
      ownerKind: ConnectionOwnerKind.session,
    );
    final second = fixture.pool.acquire(
      ownerId: 'two',
      ownerKind: ConnectionOwnerKind.codex,
    );

    final attempts = [first.ensureReady(), second.ensureReady()];
    await Future<void>.delayed(Duration.zero);
    expect(fixture.resolveCalls, 1);
    gate.complete();
    await Future.wait(attempts);

    expect(fixture.resolveCalls, 1);
    expect(fixture.clients.single.paths.where((path) => path == '/ping'), [
      '/ping',
    ]);
  });

  test(
    'session request headers remain isolated across concurrent owners',
    () async {
      final fixture = _PoolFixture(_serverA);
      addTearDown(fixture.dispose);
      final a = fixture.pool.acquire(
        ownerId: 'session-a',
        ownerKind: ConnectionOwnerKind.session,
      );
      final b = fixture.pool.acquire(
        ownerId: 'session-b',
        ownerKind: ConnectionOwnerKind.session,
      );
      final home = fixture.pool.acquire(
        ownerId: 'home',
        ownerKind: ConnectionOwnerKind.serverHome,
      );

      await Future.wait([
        a.rpc('pty.list', scope: const SessionRequestScope('attachment-a')),
        b.rpc('pty.list', scope: const SessionRequestScope('attachment-b')),
        home.rpc('session.list', retry: RpcRetryPolicy.safeOnce),
      ]);

      final requests = fixture.clients.single.requests
          .where((request) => request.url.path.startsWith('/rpc/'))
          .toList();
      expect(requests[0].headers['X-Motif-Session'], 'attachment-a');
      expect(requests[1].headers['X-Motif-Session'], 'attachment-b');
      expect(requests[2].headers.containsKey('X-Motif-Session'), isFalse);
      for (final request in requests) {
        expect(request.headers['Authorization'], 'Bearer token-a');
      }
    },
  );

  test(
    'WebSockets are exclusive and are never returned from an idle cache',
    () async {
      final fixture = _PoolFixture(_serverA);
      addTearDown(fixture.dispose);
      final owner = fixture.pool.acquire(
        ownerId: 'codex',
        ownerKind: ConnectionOwnerKind.codex,
      );

      final first = await owner.openWebSocket(
        const ServerWebSocketRequest(path: '/codex'),
      );
      final second = await owner.openWebSocket(
        const ServerWebSocketRequest(path: '/codex'),
      );
      await first.close();
      final third = await owner.openWebSocket(
        const ServerWebSocketRequest(path: '/codex'),
      );

      expect(fixture.sockets, hasLength(3));
      expect(identical(first, second), isFalse);
      expect(identical(first, third), isFalse);
    },
  );

  test('closing one owner leaves another owner and its socket alive', () async {
    final fixture = _PoolFixture(_serverA);
    addTearDown(fixture.dispose);
    final codex = fixture.pool.acquire(
      ownerId: 'codex',
      ownerKind: ConnectionOwnerKind.codex,
    );
    final session = fixture.pool.acquire(
      ownerId: 'session',
      ownerKind: ConnectionOwnerKind.session,
    );
    await codex.openWebSocket(const ServerWebSocketRequest(path: '/codex'));
    await session.openWebSocket(const ServerWebSocketRequest(path: '/events'));

    await codex.close();

    expect(fixture.sockets[0].closed, isTrue);
    expect(fixture.sockets[1].closed, isFalse);
    await session.rpc('pty.list');
    expect(fixture.pool.snapshot.activeOwners, 1);
  });

  test(
    'route generation change closes old sockets and uses a new HTTP client',
    () async {
      final fixture = _PoolFixture(_serverA);
      addTearDown(fixture.dispose);
      final owner = fixture.pool.acquire(
        ownerId: 'session',
        ownerKind: ConnectionOwnerKind.session,
      );
      final oldSocket = await owner.openWebSocket(
        const ServerWebSocketRequest(path: '/events'),
      );
      final oldGeneration = oldSocket.routeGeneration;

      await fixture.pool.reconnect(cause: StateError('network changed'));
      final newSocket = await owner.openWebSocket(
        const ServerWebSocketRequest(path: '/events'),
      );

      expect(oldSocket.done, completes);
      expect(fixture.sockets.first.closed, isTrue);
      expect(newSocket.routeGeneration, greaterThan(oldGeneration));
      expect(fixture.clients, hasLength(2));
      expect(fixture.clients.first.closeCount, 1);
    },
  );

  test(
    'one Codex socket loss with a healthy ping keeps Session sockets',
    () async {
      final fixture = _PoolFixture(_serverA);
      addTearDown(fixture.dispose);
      final codex = fixture.pool.acquire(
        ownerId: 'codex',
        ownerKind: ConnectionOwnerKind.codex,
      );
      final session = fixture.pool.acquire(
        ownerId: 'session',
        ownerKind: ConnectionOwnerKind.session,
      );
      await codex.openWebSocket(const ServerWebSocketRequest(path: '/codex'));
      final sessionSocket = await session.openWebSocket(
        const ServerWebSocketRequest(path: '/events'),
      );
      final generation = sessionSocket.routeGeneration;

      await fixture.sockets.first.closeFromServer();
      await _waitFor(
        () =>
            fixture.clients.single.paths
                .where((path) => path == '/ping')
                .length ==
            2,
      );

      expect(fixture.sockets[1].closed, isFalse);
      expect(fixture.pool.snapshot.routeGeneration, generation);
      expect(fixture.clients, hasLength(1));
    },
  );

  test(
    'failed route ping after socket loss retires the whole generation',
    () async {
      final fixture = _PoolFixture(_serverA);
      addTearDown(fixture.dispose);
      final codex = fixture.pool.acquire(
        ownerId: 'codex',
        ownerKind: ConnectionOwnerKind.codex,
      );
      final session = fixture.pool.acquire(
        ownerId: 'session',
        ownerKind: ConnectionOwnerKind.session,
      );
      await codex.openWebSocket(const ServerWebSocketRequest(path: '/codex'));
      final oldSessionSocket = await session.openWebSocket(
        const ServerWebSocketRequest(path: '/events'),
      );
      fixture.pingFailuresRemaining = 1;

      await fixture.sockets.first.closeFromServer();
      await _waitFor(() => fixture.clients.length == 2);

      expect(oldSessionSocket.done, completes);
      expect(fixture.sockets[1].closed, isTrue);
      expect(fixture.pool.snapshot.phase, ServerConnectionPoolPhase.ready);
      expect(fixture.pool.snapshot.routeGeneration, greaterThan(1));
    },
  );

  test('safeOnce read recovers once on a transport failure', () async {
    final fixture = _PoolFixture(
      _serverA,
      failPath: '/rpc/session.list',
      failuresRemaining: 1,
    );
    addTearDown(fixture.dispose);
    final home = fixture.pool.acquire(
      ownerId: 'home',
      ownerKind: ConnectionOwnerKind.serverHome,
    );

    final response = await home.rpc(
      'session.list',
      retry: RpcRetryPolicy.safeOnce,
    );

    expect(response.body, isEmpty);
    expect(fixture.clients, hasLength(2));
    expect(fixture.resolveCalls, 2);
  });

  test(
    'mutation transport failure is not replayed and reports uncertainty',
    () async {
      final fixture = _PoolFixture(
        _serverA,
        failPath: '/rpc/session.destroy',
        failuresRemaining: 1,
      );
      addTearDown(fixture.dispose);
      final session = fixture.pool.acquire(
        ownerId: 'session',
        ownerKind: ConnectionOwnerKind.session,
      );

      await expectLater(
        session.rpc('session.destroy', params: const {'name': 'dev'}),
        throwsA(isA<UncertainDeliveryException>()),
      );
      await _waitFor(() => fixture.clients.length == 2);

      final mutationAttempts = fixture.clients
          .expand((client) => client.paths)
          .where((path) => path == '/rpc/session.destroy');
      expect(mutationAttempts, hasLength(1));
    },
  );
}

final class _PoolFixture {
  _PoolFixture(
    this.server, {
    this.resolveGate,
    this.failPath,
    this.failuresRemaining = 0,
  }) {
    pool = DefaultServerConnectionPool(
      serverId: server.id,
      serverProvider: () => server,
      resolveRoute: (profile) async {
        resolveCalls++;
        await resolveGate;
        return TransportReady(target: profile, proxy: ProxySettings.none);
      },
      stopForwarder: (_) async {},
      forgetLearnedRoute: (_) {},
      learnRoute: (_, _) => false,
      healthTtl: const Duration(minutes: 1),
      httpClientFactory: (_, _) {
        late final _RecordingClient client;
        client = _RecordingClient((request) async {
          if (request.url.path == failPath && failuresRemaining > 0) {
            failuresRemaining--;
            throw http.ClientException('connection reset', request.url);
          }
          if (request.url.path == '/ping') {
            if (pingFailuresRemaining > 0) {
              pingFailuresRemaining--;
              throw http.ClientException('route unavailable', request.url);
            }
            return http.StreamedResponse(
              Stream.value(
                Uint8List.fromList(
                  utf8.encode(
                    jsonEncode(const {
                      'service': 'motif-server',
                      'version': 'test',
                    }),
                  ),
                ),
              ),
              200,
            );
          }
          return http.StreamedResponse(
            Stream.value(Uint8List.fromList(utf8.encode('{}'))),
            200,
          );
        });
        clients.add(client);
        return client;
      },
      webSocketConnector:
          ({required uri, required headers, required proxy, required certPin}) {
            final socket = _FakeWebSocket();
            sockets.add(socket);
            return socket;
          },
    );
  }

  final MotifServer server;
  final Future<void>? resolveGate;
  final String? failPath;
  int failuresRemaining;
  int pingFailuresRemaining = 0;
  late final DefaultServerConnectionPool pool;
  int resolveCalls = 0;
  final List<_RecordingClient> clients = [];
  final List<_FakeWebSocket> sockets = [];

  Future<void> dispose() => pool.dispose();
}

final class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;
  final List<http.BaseRequest> requests = [];
  final List<String> paths = [];
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    paths.add(request.url.path);
    return handler(request);
  }

  @override
  void close() => closeCount++;
}

final class _FakeWebSocket
    with StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _FakeWebSocket() {
    sink = _FakeSink(() async {
      closed = true;
      if (!_incoming.isClosed) await _incoming.close();
    });
  }

  final StreamController<Object?> _incoming = StreamController<Object?>();
  bool closed = false;

  Future<void> closeFromServer() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

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

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
