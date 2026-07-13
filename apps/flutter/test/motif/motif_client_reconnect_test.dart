import 'dart:convert';

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
