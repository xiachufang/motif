import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('representative generated protocol messages round-trip', () {
    final requestJson = <String, Object?>{
      'method': 'initialize',
      'id': 7,
      'params': {
        'capabilities': {'experimentalApi': true},
        'clientInfo': {'name': 'motif', 'title': 'Motif', 'version': '1.2.3'},
      },
    };
    final request = CodexClientRequest.fromJson(requestJson);
    expect(request, isA<CodexInitializeRequest>());
    expect(request.toJson(), requestJson);

    final responseJson = <String, Object?>{
      'codexHome': '/tmp/codex',
      'platformFamily': 'unix',
      'platformOs': 'macos',
      'userAgent': 'codex-test',
    };
    expect(
      CodexInitializeResponse.fromJson(responseJson).toJson(),
      responseJson,
    );

    final notificationJson = <String, Object?>{'method': 'initialized'};
    expect(
      CodexClientNotification.fromJson(notificationJson).toJson(),
      notificationJson,
    );

    final errorJson = <String, Object?>{
      'id': 7,
      'error': {
        'code': -32000,
        'message': 'not ready',
        'data': {'retryable': true},
      },
    };
    expect(CodexJSONRPCError.fromJson(errorJson).toJson(), errorJson);
  });

  test(
    'performs experimental initialize then initialized and detaches',
    () async {
      late final _FakeWebSocket socket;
      final sent = <Map<String, Object?>>[];
      socket = _FakeWebSocket((message) {
        final json = (jsonDecode(message as String) as Map)
            .cast<String, Object?>();
        sent.add(json);
        if (json['method'] == 'initialize') {
          scheduleMicrotask(
            () => socket.addIncoming(
              jsonEncode({
                'id': json['id'],
                'result': {
                  'codexHome': '/tmp/codex',
                  'platformFamily': 'unix',
                  'platformOs': 'macos',
                  'userAgent': 'codex-cli/0.147.0',
                },
              }),
            ),
          );
        }
      });
      final transport = _FakeTransport(socket);
      final controller = CodexConnectionController(
        transport: transport,
        appVersionProvider: () async => '1.2.3',
      );

      await controller.start();

      expect(transport.connectCount, 1);
      expect(controller.state.phase, CodexConnectionPhase.connected);
      expect(controller.state.response?.platformOs, 'macos');
      expect(sent.map((message) => message['method']), [
        'initialize',
        'initialized',
      ]);
      expect(sent.first['params'], {
        'capabilities': {'experimentalApi': true},
        'clientInfo': {'name': 'motif', 'title': 'Motif', 'version': '1.2.3'},
      });

      await controller.close();
      expect(transport.closeCount, 1);
    },
  );

  test('unknown notification is retained as raw and typed fallback', () async {
    late final _FakeWebSocket socket;
    socket = _FakeWebSocket((message) {
      final json = jsonDecode(message as String) as Map;
      if (json['method'] == 'initialize') {
        scheduleMicrotask(
          () => socket.addIncoming(
            jsonEncode({
              'id': json['id'],
              'result': {
                'codexHome': '/tmp/codex',
                'platformFamily': 'unix',
                'platformOs': 'linux',
                'userAgent': 'codex-test',
              },
            }),
          ),
        );
      }
    });
    final controller = CodexConnectionController(
      transport: _FakeTransport(socket),
      appVersionProvider: () async => '1.0.0',
    );
    final raw = <Map<String, Object?>>[];
    final typed = <CodexJsonEncodable>[];
    final rawSub = controller.rawMessages.listen(raw.add);
    final typedSub = controller.typedMessages.listen(typed.add);
    await controller.start();

    socket.addIncoming(
      jsonEncode({
        'method': 'future/notification',
        'params': {'value': 1},
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(raw.last['method'], 'future/notification');
    expect(typed.last, isA<CodexUnknownMessage>());

    await rawSub.cancel();
    await typedSub.cancel();
    await controller.close();
  });

  test('JSON-RPC initialization error can be retried', () async {
    _FakeWebSocket respondingSocket({required bool fail}) {
      late final _FakeWebSocket socket;
      socket = _FakeWebSocket((message) {
        final json = jsonDecode(message as String) as Map;
        if (json['method'] != 'initialize') return;
        scheduleMicrotask(
          () => socket.addIncoming(
            jsonEncode({
              'id': json['id'],
              if (fail)
                'error': {'code': -32000, 'message': 'not ready'}
              else
                'result': {
                  'codexHome': '/tmp/codex',
                  'platformFamily': 'unix',
                  'platformOs': 'linux',
                  'userAgent': 'codex-retry',
                },
            }),
          ),
        );
      });
      return socket;
    }

    final transport = _RetryTransport([
      respondingSocket(fail: true),
      respondingSocket(fail: false),
    ]);
    final controller = CodexConnectionController(
      transport: transport,
      appVersionProvider: () async => '1.0.0',
    );

    await controller.start();
    expect(controller.state.phase, CodexConnectionPhase.failed);
    expect(controller.state.error, contains('not ready'));

    await controller.retry();
    expect(controller.state.phase, CodexConnectionPhase.connected);
    expect(controller.state.response?.userAgent, 'codex-retry');
    expect(transport.closeCount, 1);
    await controller.close();
    expect(transport.closeCount, 2);
  });

  test(
    'typed requests use generated wire shapes and correlate responses',
    () async {
      late final _FakeWebSocket socket;
      final sent = <Map<String, Object?>>[];
      socket = _FakeWebSocket((message) {
        final json = (jsonDecode(message as String) as Map)
            .cast<String, Object?>();
        sent.add(json);
        final id = json['id'];
        Object? result;
        Object? error;
        switch (json['method']) {
          case 'initialize':
            result = {
              'codexHome': '/tmp/codex',
              'platformFamily': 'unix',
              'platformOs': 'macos',
              'userAgent': 'codex-test',
            };
          case 'thread/list':
            result = {'data': <Object?>[], 'nextCursor': null};
          case 'thread/read':
            result = {'thread': threadJson('thread-1')};
          case 'thread/start':
            result = {
              'approvalPolicy': 'never',
              'approvalsReviewer': 'user',
              'cwd': '/work/new-project',
              'model': 'codex-test',
              'modelProvider': 'openai',
              'sandbox': {'type': 'dangerFullAccess'},
              'thread': {
                ...threadJson('thread-new'),
                'cwd': '/work/new-project',
              },
            };
          case 'thread/fork':
            result = {
              'approvalPolicy': 'never',
              'approvalsReviewer': 'user',
              'cwd': '/work/motif',
              'model': 'codex-test',
              'modelProvider': 'openai',
              'sandbox': {'type': 'dangerFullAccess'},
              'thread': threadJson('thread-fork'),
            };
          case 'thread/unsubscribe':
            result = {'status': 'unsubscribed'};
          case 'fs/readFile':
            result = {'dataBase64': 'e30='};
          case 'fs/watch':
            result = {'path': '/tmp/state.json'};
          case 'fs/unwatch':
            result = <String, Object?>{};
          case 'fs/createDirectory':
          case 'fs/writeFile':
          case 'turn/interrupt':
            result = <String, Object?>{};
          case 'turn/start':
            result = {
              'turn': {
                'id': 'turn-1',
                'items': <Object?>[],
                'status': 'inProgress',
              },
            };
          case 'turn/steer':
            result = {'turnId': 'turn-1'};
          case 'model/list':
          case 'permissionProfile/list':
            result = {'data': <Object?>[]};
          case 'collaborationMode/list':
          case 'skills/list':
            result = {'data': <Object?>[]};
          case 'plugin/list':
            result = {'marketplaces': <Object?>[]};
          case 'thread/goal/get':
            result = {'goal': null};
          case 'thread/resume':
            error = {'code': -32000, 'message': 'resume unavailable'};
          default:
            return;
        }
        scheduleMicrotask(
          () => socket.addIncoming(
            jsonEncode({
              'id': id,
              if (error != null) 'error': error else 'result': result,
            }),
          ),
        );
      });
      final controller = CodexConnectionController(
        transport: _FakeTransport(socket),
        appVersionProvider: () async => '1.0.0',
      );
      await controller.start();

      final list = await controller.listThreads(
        const CodexThreadListParams(
          archived: false,
          limit: 100,
          sortDirection: CodexSortDirection.desc,
          sortKey: CodexThreadSortKey.recencyAt,
        ),
      );
      expect(list.data, isEmpty);
      expect((await controller.readThread('thread-1')).thread.id, 'thread-1');
      expect(
        (await controller.startThread(
          const CodexThreadStartParams(
            cwd: '/work/new-project',
            model: 'codex-test',
            permissions: 'full-access',
          ),
        )).thread.id,
        'thread-new',
      );
      expect(
        (await controller.forkThread(
          const CodexThreadForkParams(
            threadId: 'thread-1',
            lastTurnId: 'turn-0',
          ),
        )).thread.id,
        'thread-fork',
      );
      expect(
        (await controller.unsubscribeThread('thread-fork')).status,
        CodexThreadUnsubscribeStatus.unsubscribed,
      );
      expect((await controller.readFile('/tmp/state.json')).dataBase64, 'e30=');
      expect(
        (await controller.watchFile('/tmp/state.json', 'watch')).path.value,
        '/tmp/state.json',
      );
      await controller.unwatchFile('watch');
      expect(
        (await controller.startTurn(
          const CodexTurnStartParams(
            effort: CodexReasoningEffort('high'),
            input: [CodexTextUserInput(text: 'hello')],
            model: 'codex-test',
            permissions: 'full-access',
            threadId: 'thread-1',
          ),
        )).turn.id,
        'turn-1',
      );
      expect(
        (await controller.steerTurn(
          const CodexTurnSteerParams(
            expectedTurnId: 'turn-1',
            input: [CodexTextUserInput(text: 'follow-up')],
            threadId: 'thread-1',
          ),
        )).turnId,
        'turn-1',
      );
      await controller.interruptTurn('thread-1', 'turn-1');
      expect(
        (await controller.listModels(const CodexModelListParams())).data,
        isEmpty,
      );
      expect(
        (await controller.listPermissionProfiles(
          const CodexPermissionProfileListParams(cwd: '/work/motif'),
        )).data,
        isEmpty,
      );
      expect((await controller.listCollaborationModes()).data, isEmpty);
      expect(
        (await controller.listSkills(
          const CodexSkillsListParams(cwds: ['/work/motif']),
        )).data,
        isEmpty,
      );
      expect(
        (await controller.listPlugins(
          const CodexPluginListParams(
            cwds: [CodexV2AbsolutePathBuf('/work/motif')],
          ),
        )).marketplaces,
        isEmpty,
      );
      expect((await controller.getThreadGoal('thread-1')).goal, isNull);
      await controller.createDirectory('/tmp/attachments');
      await controller.writeFile('/tmp/attachments/a.txt', 'aGVsbG8=');
      await controller.respondToServerRequest(
        const CodexV2RequestId(99),
        const CodexToolRequestUserInputResponse(answers: {}),
      );
      await expectLater(
        controller.resumeThread('thread-1'),
        throwsA(isA<CodexRpcException>()),
      );

      final requests = {
        for (final message in sent)
          if (message['method'] is String) message['method']: message,
      };
      expect(requests['thread/list']?['params'], {
        'archived': false,
        'limit': 100,
        'sortDirection': 'desc',
        'sortKey': 'recency_at',
      });
      expect(requests['thread/read']?['params'], {
        'includeTurns': false,
        'threadId': 'thread-1',
      });
      expect(requests['thread/start']?['params'], {
        'cwd': '/work/new-project',
        'model': 'codex-test',
        'permissions': 'full-access',
      });
      expect(requests['thread/fork']?['params'], {
        'lastTurnId': 'turn-0',
        'threadId': 'thread-1',
      });
      expect(requests['thread/unsubscribe']?['params'], {
        'threadId': 'thread-fork',
      });
      expect(requests['fs/readFile']?['params'], {'path': '/tmp/state.json'});
      expect(requests['fs/watch']?['params'], {
        'path': '/tmp/state.json',
        'watchId': 'watch',
      });
      expect(requests['fs/unwatch']?['params'], {'watchId': 'watch'});
      expect(requests['thread/resume']?['params'], {
        'excludeTurns': true,
        'threadId': 'thread-1',
      });
      expect(requests['turn/start']?['params'], {
        'effort': 'high',
        'input': [
          {'type': 'text', 'text': 'hello'},
        ],
        'model': 'codex-test',
        'permissions': 'full-access',
        'threadId': 'thread-1',
      });
      expect(requests['turn/steer']?['params'], {
        'expectedTurnId': 'turn-1',
        'input': [
          {'type': 'text', 'text': 'follow-up'},
        ],
        'threadId': 'thread-1',
      });
      expect(requests['turn/interrupt']?['params'], {
        'threadId': 'thread-1',
        'turnId': 'turn-1',
      });
      expect(requests['permissionProfile/list']?['params'], {
        'cwd': '/work/motif',
      });
      expect(requests['collaborationMode/list']?['params'], isEmpty);
      expect(requests['skills/list']?['params'], {
        'cwds': ['/work/motif'],
      });
      expect(requests['plugin/list']?['params'], {
        'cwds': ['/work/motif'],
      });
      expect(requests['fs/createDirectory']?['params'], {
        'path': '/tmp/attachments',
        'recursive': true,
      });
      expect(requests['fs/writeFile']?['params'], {
        'dataBase64': 'aGVsbG8=',
        'path': '/tmp/attachments/a.txt',
      });
      expect(sent.where((message) => message['id'] == 99).single['result'], {
        'answers': <String, Object?>{},
      });
      final ids = requests.values
          .where((request) => request['id'] != null)
          .map((request) => request['id'])
          .toSet();
      expect(ids, hasLength(21));
      await controller.close();
    },
  );
}

Map<String, Object?> threadJson(String id) => {
  'id': id,
  'sessionId': id,
  'preview': '',
  'modelProvider': 'openai',
  'createdAt': 1,
  'updatedAt': 1,
  'status': {'type': 'notLoaded'},
  'ephemeral': false,
  'turns': <Object?>[],
  'source': 'cli',
  'cwd': '/work/motif',
  'cliVersion': 'test',
};

final class _FakeTransport implements CodexTransport {
  _FakeTransport(this.socket);
  final WebSocketChannel socket;
  int connectCount = 0;
  int closeCount = 0;

  @override
  Future<void> connect() async => connectCount++;

  @override
  WebSocketChannel openCodexWebSocket() => socket;

  @override
  Future<void> close() async => closeCount++;
}

final class _RetryTransport implements CodexTransport {
  _RetryTransport(this.sockets);
  final List<WebSocketChannel> sockets;
  int index = -1;
  int closeCount = 0;

  @override
  Future<void> connect() async => index++;

  @override
  WebSocketChannel openCodexWebSocket() => sockets[index];

  @override
  Future<void> close() async => closeCount++;
}

final class _FakeWebSocket
    with StreamChannelMixin<Object?>
    implements WebSocketChannel {
  _FakeWebSocket(void Function(Object?) onSend) {
    sink = _FakeSink(onSend, _incoming.close);
  }

  final StreamController<Object?> _incoming = StreamController<Object?>();

  void addIncoming(Object? message) => _incoming.add(message);

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
  _FakeSink(this.onSend, this.onClose);
  final void Function(Object?) onSend;
  final Future<void> Function() onClose;
  final Completer<void> _done = Completer<void>();

  @override
  void add(Object? event) => onSend(event);

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
    await onClose();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
