import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rpc_client.dart';
import 'package:motif/motif/state/motif_client.dart';

const _server = MotifServer(
  id: 'local',
  name: 'Local',
  host: '127.0.0.1',
  port: 12345,
);

void main() {
  tearDown(() {
    RpcClient.debugHttpClientFactory = null;
  });

  test(
    'missing intended session recovers to connected session picker',
    () async {
      RpcClient.debugHttpClientFactory = () => MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/ping') {
          return http.Response(
            jsonEncode({'service': 'motif-server', 'version': 'test'}),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/rpc/session.attach') {
          return http.Response(
            jsonEncode({'code': -32007, 'message': "session 'dev' not found"}),
            404,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/rpc/session.list') {
          return http.Response(jsonEncode({'sessions': []}), 200);
        }
        return http.Response('', 404);
      });

      final motif = MotifClient()
        ..intendedSession = 'dev'
        ..lastSeq = 42
        ..resumeSeqs['dev'] = 42
        ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
        ..views = const [ViewInfo(id: 'view-1', spec: PtyViewSpec('pty-1'))]
        ..activeViewId = 'view-1';

      await motif.connect(_server, force: true);
      await Future<void>.delayed(Duration.zero);

      expect(motif.state, isA<ConnConnected>());
      expect(motif.isLive, isTrue);
      expect(motif.intendedSession, isNull);
      expect(motif.resumeSeqs, isNot(contains('dev')));
      expect(motif.ptys, isEmpty);
      expect(motif.views, isEmpty);
      expect(motif.activeViewId, isNull);
      expect(motif.lastSeq, 0);
      expect(motif.connectionNotice, isNull);
    },
  );

  test('transient reattach failure stays failed for reconnect retry', () async {
    RpcClient.debugHttpClientFactory = () => MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/ping') {
        return http.Response(
          jsonEncode({'service': 'motif-server', 'version': 'test'}),
          200,
        );
      }
      if (request.method == 'POST' &&
          request.url.path == '/rpc/session.attach') {
        return http.Response(
          jsonEncode({'code': -32603, 'message': 'motifd still booting'}),
          500,
        );
      }
      return http.Response('', 404);
    });

    final motif = MotifClient()
      ..intendedSession = 'dev'
      ..lastSeq = 42
      ..resumeSeqs['dev'] = 42
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'view-1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'view-1';

    await motif.connect(_server, force: true);

    expect(motif.state, isA<ConnFailed>());
    expect((motif.state as ConnFailed).message, contains('reattach failed'));
    expect(motif.isLive, isFalse);
    expect(motif.intendedSession, 'dev');
    expect(motif.resumeSeqs['dev'], 42);
    expect(motif.ptys, isNotEmpty);
    expect(motif.views, isNotEmpty);
    expect(motif.activeViewId, 'view-1');
  });

  test('terminal resize waits for reattach before sending RPC', () async {
    final attachStarted = Completer<void>();
    final releaseAttach = Completer<void>();
    final resizeSessionHeaders = <String?>[];
    final eventSockets = <WebSocket>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      for (final socket in eventSockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    server.listen((request) async {
      if (request.method == 'GET' && request.uri.path == '/ping') {
        request.response.write(
          jsonEncode({'service': 'motif-server', 'version': 'test'}),
        );
        await request.response.close();
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == '/rpc/session.attach') {
        if (!attachStarted.isCompleted) attachStarted.complete();
        await releaseAttach.future;
        request.response.headers.set('X-Motif-Session', 'sid-1');
        request.response.write(
          jsonEncode({
            'session': {'name': 'dev'},
            'ptys': [
              {'id': 'pty-1', 'cols': 80, 'rows': 24},
            ],
            'views': [
              {
                'id': 'view-1',
                'spec': {'kind': 'pty', 'pty_id': 'pty-1'},
              },
            ],
            'active_view': 'view-1',
            'last_seq': 0,
          }),
        );
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/events') {
        eventSockets.add(await WebSocketTransformer.upgrade(request));
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/rpc/pty.resize') {
        resizeSessionHeaders.add(request.headers.value('X-Motif-Session'));
        request.response.write('{}');
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final motif = MotifClient()
      ..intendedSession = 'dev'
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'view-1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'view-1';
    addTearDown(motif.disconnect);
    final localServer = MotifServer(
      id: 'local-test',
      name: 'Local test',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
    );

    final connecting = motif.connect(localServer, force: true);
    await attachStarted.future;
    expect(motif.state, isA<ConnConnecting>());
    expect(motif.canInput, isFalse);

    var resizeCompleted = false;
    final resizing = motif
        .resizePty('pty-1', 120, 40)
        .whenComplete(() => resizeCompleted = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(resizeCompleted, isFalse);
    expect(resizeSessionHeaders, isEmpty);

    releaseAttach.complete();
    await Future.wait([connecting, resizing]);

    expect(motif.state, isA<ConnAttached>());
    expect(motif.canInput, isTrue);
    expect(resizeSessionHeaders, ['sid-1']);
  });

  test('terminal resize reattaches once when session id expired', () async {
    var attachCount = 0;
    var expiredResizeCount = 0;
    final freshResizeSeen = Completer<void>();
    final attachSessionHeaders = <String?>[];
    final resizeSessionHeaders = <String?>[];
    final eventSockets = <WebSocket>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      for (final socket in eventSockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    server.listen((request) async {
      if (request.method == 'GET' && request.uri.path == '/ping') {
        request.response.write(
          jsonEncode({'service': 'motif-server', 'version': 'test'}),
        );
        await request.response.close();
        return;
      }
      if (request.method == 'POST' &&
          request.uri.path == '/rpc/session.attach') {
        attachSessionHeaders.add(request.headers.value('X-Motif-Session'));
        attachCount++;
        request.response.headers.set('X-Motif-Session', 'sid-$attachCount');
        request.response.write(
          jsonEncode({
            'session': {'name': 'dev'},
            'ptys': [
              {'id': 'pty-1', 'cols': 80, 'rows': 24},
            ],
            'views': [
              {
                'id': 'view-1',
                'spec': {'kind': 'pty', 'pty_id': 'pty-1'},
              },
            ],
            'active_view': 'view-1',
            'last_seq': 0,
          }),
        );
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/events') {
        eventSockets.add(await WebSocketTransformer.upgrade(request));
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/rpc/pty.resize') {
        final sid = request.headers.value('X-Motif-Session');
        resizeSessionHeaders.add(sid);
        if (sid == 'sid-1') {
          expiredResizeCount++;
          if (expiredResizeCount == 2) {
            // Let the second stale response arrive after the first request has
            // installed sid-2. It must reuse that recovery, not start a third
            // attach and invalidate the fresh id.
            await freshResizeSeen.future;
          }
          request.response.statusCode = HttpStatus.conflict;
          request.response.write(
            jsonEncode({
              'code': -32009,
              'message': 'must session.attach first',
            }),
          );
        } else {
          if (!freshResizeSeen.isCompleted) freshResizeSeen.complete();
          request.response.write('{}');
        }
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final motif = MotifClient()..intendedSession = 'dev';
    addTearDown(motif.disconnect);
    final localServer = MotifServer(
      id: 'local-test',
      name: 'Local test',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
    );

    await motif.connect(localServer, force: true);
    await Future.wait([
      motif.resizePty('pty-1', 120, 40),
      motif.resizePty('pty-1', 121, 41),
    ]);

    expect(attachCount, 2);
    expect(attachSessionHeaders, [null, null]);
    expect(resizeSessionHeaders.where((sid) => sid == 'sid-1'), hasLength(2));
    expect(resizeSessionHeaders.where((sid) => sid == 'sid-2'), hasLength(2));
    expect(motif.state, isA<ConnAttached>());
    expect(motif.canInput, isTrue);
  });

  test(
    'destroying owned session releases it but keeps server connected',
    () async {
      var destroyed = false;
      var detached = false;
      RpcClient.debugHttpClientFactory = () => MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/ping') {
          return http.Response(
            jsonEncode({'service': 'motif-server', 'version': 'test'}),
            200,
          );
        }
        if (request.method == 'POST' &&
            request.url.path == '/rpc/session.detach') {
          detached = true;
          return http.Response('{}', 200);
        }
        if (request.method == 'POST' &&
            request.url.path == '/rpc/session.destroy') {
          destroyed = true;
          return http.Response('{}', 200);
        }
        if (request.method == 'POST' &&
            request.url.path == '/rpc/session.list') {
          return http.Response(
            jsonEncode({
              'sessions': destroyed
                  ? <Object?>[]
                  : [
                      {'name': 'dev'},
                    ],
            }),
            200,
          );
        }
        return http.Response('', 404);
      });

      final motif = MotifClient();
      await motif.connect(_server, force: true);
      await Future<void>.delayed(Duration.zero);
      motif
        ..prepareSessionReconnect('dev')
        ..lastSeq = 42
        ..resumeSeqs['dev'] = 42
        ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
        ..views = const [ViewInfo(id: 'view-1', spec: PtyViewSpec('pty-1'))]
        ..activeViewId = 'view-1';

      await motif.destroySession('dev');

      expect(detached, isTrue);
      expect(destroyed, isTrue);
      expect(motif.isLive, isTrue);
      expect(motif.state, isA<ConnConnected>());
      expect(motif.intendedSession, isNull);
      expect(motif.resumeSeqs, isNot(contains('dev')));
      expect(motif.sessions, isEmpty);
      expect(motif.ptys, isEmpty);
      expect(motif.views, isEmpty);
      expect(motif.activeViewId, isNull);
      expect(motif.lastSeq, 0);
    },
  );
}
