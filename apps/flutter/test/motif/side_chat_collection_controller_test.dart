import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:motif/motif/codex/side_chat_collection_controller.dart';
import 'package:motif/motif/ui/screens/side_chat_screen.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';

void main() {
  test(
    'forks ephemeral conversations directly from the fixed parent',
    () async {
      final client = _SideChatFakeClient();
      final collection = SideChatCollectionController(
        serverId: 'server',
        parentThreadId: 'parent-thread',
        connection: client,
      );

      final first = await collection.ensureInitial();
      final second = await collection.createSideChat();

      expect(first?.name, 'Side Chat 1');
      expect(second?.name, 'Side Chat 2');
      expect(client.forks, hasLength(2));
      for (final params in client.forks) {
        expect(params.threadId, 'parent-thread');
        expect(params.ephemeral, isTrue);
        expect(params.excludeTurns, isTrue);
        expect(params.lastTurnId, isNull);
      }
      expect(client.listCalls, 0);
      expect(client.goalCalls, 0);
      expect(
        await first!.conversation.saveGoal(objective: 'Unsupported goal'),
        isFalse,
      );
      await first.conversation.clearGoal();
      expect(client.goalCalls, 0);
      expect(collection.entries.map((entry) => entry.name), [
        'Side Chat 2',
        'Side Chat 1',
      ]);
      expect(await collection.ensureInitial(), same(second));
      expect(client.forks, hasLength(2));

      client.emit(
        CodexTurnStartedNotification2(
          params: CodexTurnStartedNotification(
            threadId: first.id,
            turn: const CodexTurn(
              id: 'background-turn',
              items: [],
              status: CodexTurnStatus.inProgress,
            ),
          ),
        ),
      );
      await _waitFor(() => first.conversation.activeTurn != null);
      expect(collection.entries.first.id, first.id);

      await collection.close();
      expect(client.unsubscribed, containsAll([first.id, second!.id]));
      expect(client.closed, isTrue);
    },
  );

  test('a connection restart expires all ephemeral conversations', () async {
    final client = _SideChatFakeClient();
    final collection = SideChatCollectionController(
      serverId: 'server',
      parentThreadId: 'parent-thread',
      connection: client,
    );

    await collection.ensureInitial();
    expect(collection.entries, hasLength(1));
    client.changePhase(CodexConnectionPhase.connecting);
    await _waitFor(() => collection.entries.isEmpty);

    expect(collection.error, contains('expired'));
    await collection.close();
  });

  testWidgets('shows only the temporary collection in a desktop split view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = _SideChatFakeClient();
    final collection = SideChatCollectionController(
      serverId: 'server',
      parentThreadId: 'parent-thread',
      connection: client,
    );
    addTearDown(collection.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: SideChatScreen(collection: collection),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byKey(const ValueKey('side-chat-sidebar')), findsOneWidget);
    expect(find.text('Side Chat 1'), findsWidgets);
    expect(find.byKey(const ValueKey('codex-thread-detail')), findsOneWidget);
    expect(find.text('Projects'), findsNothing);
    expect(find.text('Timeline'), findsNothing);
    expect(find.byKey(const ValueKey('codex-service-menu')), findsNothing);
    expect(client.listCalls, 0);
    expect(client.goalCalls, 0);
    final sidebar = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('side-chat-sidebar')),
    );
    expect(sidebar.color, MotifColors.light.surface);
    expect(find.text('Side Chats'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('side-chat-sidebar-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('side-chat-sidebar')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('side-chat-sidebar-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('side-chat-sidebar')), findsOneWidget);

    final threadId = collection.selected!.id;
    client.emit(
      CodexTurnCompletedNotification2(
        params: CodexTurnCompletedNotification(
          threadId: threadId,
          turn: const CodexTurn(
            id: 'side-turn',
            items: [
              CodexAgentMessageThreadItem(
                id: 'side-answer',
                text: 'Temporary answer',
              ),
            ],
            status: CodexTurnStatus.completed,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Temporary answer'), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-fork-side-turn')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('codex-add-menu')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('codex-add-goal')), findsNothing);
    expect(find.byKey(const ValueKey('codex-add-plan')), findsOneWidget);
    expect(client.goalCalls, 0);
  });

  testWidgets('uses a drawer on a narrow screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final collection = SideChatCollectionController(
      serverId: 'server',
      parentThreadId: 'parent-thread',
      connection: _SideChatFakeClient(),
    );
    addTearDown(collection.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: SideChatScreen(collection: collection),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byKey(const ValueKey('side-chat-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('side-chat-sidebar')).hitTestable(),
      findsOneWidget,
    );
  });
}

final class _SideChatFakeClient extends ChangeNotifier
    implements CodexAppServerClient {
  final StreamController<Map<String, Object?>> _raw =
      StreamController.broadcast();
  final StreamController<CodexJsonEncodable> _typed =
      StreamController.broadcast();
  final List<CodexThreadForkParams> forks = [];
  final List<String> unsubscribed = [];
  int listCalls = 0;
  int goalCalls = 0;
  bool closed = false;

  @override
  CodexConnectionState state = CodexConnectionState(
    phase: CodexConnectionPhase.connected,
    response: const CodexInitializeResponse(
      codexHome: CodexV2AbsolutePathBuf('/tmp/codex'),
      platformFamily: 'unix',
      platformOs: 'macos',
      userAgent: 'test',
    ),
  );

  @override
  Stream<Map<String, Object?>> get rawMessages => _raw.stream;

  @override
  Stream<CodexJsonEncodable> get typedMessages => _typed.stream;

  void emit(CodexJsonEncodable message) => _typed.add(message);

  void changePhase(CodexConnectionPhase phase) {
    state = CodexConnectionState(phase: phase, response: state.response);
    notifyListeners();
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> retry() async {}

  @override
  Future<CodexThreadListResponse> listThreads(
    CodexThreadListParams params,
  ) async {
    listCalls++;
    return const CodexThreadListResponse(data: []);
  }

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async {
    forks.add(params);
    final index = forks.length;
    final thread = CodexThread(
      cliVersion: 'test',
      createdAt: index,
      cwd: const CodexV2AbsolutePathBuf('/work/motif'),
      ephemeral: true,
      forkedFromId: params.threadId,
      id: 'side-$index',
      modelProvider: 'openai',
      name: null,
      parentThreadId: params.threadId,
      preview: '',
      sessionId: 'side-$index',
      source: const CodexSessionSource('cli'),
      status: const CodexIdleThreadStatus(),
      turns: const [],
      updatedAt: index,
    );
    return CodexThreadForkResponse(
      approvalPolicy: const CodexAskForApproval('on-request'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: thread.cwd,
      model: 'codex-test',
      modelProvider: 'openai',
      sandbox: const CodexDangerFullAccessSandboxPolicy(),
      thread: thread,
    );
  }

  @override
  Future<CodexThreadUnsubscribeResponse> unsubscribeThread(
    String threadId,
  ) async {
    unsubscribed.add(threadId);
    return const CodexThreadUnsubscribeResponse(
      status: CodexThreadUnsubscribeStatus.unsubscribed,
    );
  }

  @override
  Future<CodexThreadGoalGetResponse> getThreadGoal(String threadId) async {
    goalCalls++;
    throw StateError('ephemeral thread does not support goals');
  }

  @override
  Future<CodexThreadGoalSetResponse> setThreadGoal(
    CodexThreadGoalSetParams params,
  ) async {
    goalCalls++;
    throw StateError('ephemeral thread does not support goals');
  }

  @override
  Future<CodexThreadGoalClearResponse> clearThreadGoal(String threadId) async {
    goalCalls++;
    throw StateError('ephemeral thread does not support goals');
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  void dispose() {
    unawaited(_raw.close());
    unawaited(_typed.close());
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was not reached');
}
