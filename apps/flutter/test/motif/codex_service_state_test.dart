import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/codex_service_state.dart';
import 'package:motif/motif/codex/codex_thread_catalog.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';

void main() {
  test(
    'paginates, reads on selection, lazily resumes for send, and disposes',
    () async {
      final first = thread('first', updatedAt: 10);
      final second = thread('second', updatedAt: 20);
      final client = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(
            data: [first, thread('temporary', ephemeral: true)],
            nextCursor: 'next',
          ),
          'next': CodexThreadListResponse(
            data: [second],
            // A repeated cursor must terminate pagination.
            nextCursor: 'next',
          ),
        },
        globalState: jsonEncode({
          'local-projects': {
            'motif': {
              'id': 'motif',
              'name': 'Motif',
              'rootPaths': ['/work/motif'],
            },
          },
          'project-order': ['motif'],
          'pinned-thread-ids': ['second'],
          'projectless-thread-ids': <String>[],
          'thread-project-assignments': {
            'first': {'projectKind': 'local', 'projectId': 'motif'},
            'second': {'projectKind': 'local', 'projectId': 'motif'},
          },
        }),
      );
      final state = CodexServiceState(serverId: 'server', connection: client);

      await state.start();
      await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);

      expect(client.listParams, hasLength(2));
      expect(client.listParams.first.archived, isFalse);
      expect(client.listParams.first.limit, 100);
      expect(client.listParams.first.sortKey, CodexThreadSortKey.recencyAt);
      expect(client.listParams.first.sortDirection, CodexSortDirection.desc);
      expect(state.catalog.allThreads.map((thread) => thread.id), [
        'second',
        'first',
      ]);
      expect(state.catalog.pinnedThreads.single.id, 'second');
      expect(client.watchedPaths.single, '/tmp/codex/.codex-global-state.json');

      await state.readThread('first');
      expect(client.readThreadIds, ['first']);
      expect(client.readIncludeTurns, [true]);
      expect(client.resumedThreadIds, isEmpty);
      expect(state.selectedThread?.id, 'first');

      await Future.wait([
        state.ensureThreadResumedForSend('first'),
        state.ensureThreadResumedForSend('first'),
      ]);
      await state.ensureThreadResumedForSend('first');
      expect(client.resumedThreadIds, ['first']);

      final callsBeforeChange = client.listParams.length;
      client.emit(
        const CodexFsChangedNotification2(
          params: CodexFsChangedNotification(
            changedPaths: [],
            watchId: CodexServiceState.globalStateWatchId,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 260));
      await waitFor(() => client.listParams.length > callsBeforeChange);

      await state.close();
      expect(client.unwatchedIds, [CodexServiceState.globalStateWatchId]);
      expect(client.closed, isTrue);
      expect(client.disposed, isTrue);
    },
  );

  test('restores a valid local model preference and records changes', () async {
    final existing = thread('thread');
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [existing]),
      },
      models: const [
        CodexModel(
          defaultReasoningEffort: CodexReasoningEffort('medium'),
          description: 'Default model',
          displayName: 'Default',
          hidden: false,
          id: 'default-model',
          isDefault: true,
          model: 'default-model',
          supportedReasoningEfforts: [],
        ),
        CodexModel(
          defaultReasoningEffort: CodexReasoningEffort('high'),
          description: 'Preferred model',
          displayName: 'Preferred',
          hidden: false,
          id: 'preferred-model',
          isDefault: false,
          model: 'preferred-model',
          supportedReasoningEfforts: [],
        ),
      ],
    );
    final recorded = <String?>[];
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..configureModelPreference(
        preferredModelId: 'preferred-model',
        onSelected: recorded.add,
      );

    await state.start();
    await waitFor(() => state.models.length == 2);
    expect(state.selectedModelId, 'preferred-model');
    expect(state.selectedReasoningEffort, 'high');
    expect(recorded, isEmpty);

    state.selectModel('default-model');
    expect(recorded, ['default-model']);
    expect(state.selectedModelId, 'default-model');
    expect(state.selectedReasoningEffort, 'medium');

    await state.readThread('thread');
    await state.ensureThreadResumedForSend('thread');
    expect(state.selectedModelId, 'default-model');
    await state.close();
  });

  test('clears a local model preference that is no longer available', () async {
    final client = FakeCodexClient(
      pages: const {null: CodexThreadListResponse(data: [])},
      models: const [
        CodexModel(
          defaultReasoningEffort: CodexReasoningEffort('medium'),
          description: 'Default model',
          displayName: 'Default',
          hidden: false,
          id: 'default-model',
          isDefault: true,
          model: 'default-model',
          supportedReasoningEfforts: [],
        ),
      ],
    );
    final recorded = <String?>[];
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..configureModelPreference(
        preferredModelId: 'removed-model',
        onSelected: recorded.add,
      );

    await state.start();
    await waitFor(() => state.models.isNotEmpty);
    expect(recorded, [isNull]);
    expect(state.selectedModelId, 'default-model');
    await state.close();
  });

  test(
    'thread clicks switch highlight immediately and latest read wins',
    () async {
      final first = thread('first', updatedAt: 10);
      final second = thread('second', updatedAt: 20);
      final client = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(data: [first, second]),
        },
      );
      final firstRead = Completer<CodexThreadReadResponse>();
      final secondRead = Completer<CodexThreadReadResponse>();
      client.readGates
        ..['first'] = firstRead
        ..['second'] = secondRead;
      final state = CodexServiceState(serverId: 'server', connection: client);
      await state.start();
      await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);

      final pendingFirst = state.readThread('first');
      expect(state.selectedThread?.id, 'first');
      expect(state.readingThreadId, 'first');

      final pendingSecond = state.readThread('second');
      expect(state.selectedThread?.id, 'second');
      expect(state.readingThreadId, 'second');

      firstRead.complete(CodexThreadReadResponse(thread: first));
      await pendingFirst;
      expect(state.selectedThread?.id, 'second');
      expect(state.readingThreadId, 'second');

      secondRead.complete(CodexThreadReadResponse(thread: second));
      await pendingSecond;
      expect(state.selectedThread?.id, 'second');
      expect(state.readingThreadId, isNull);
      expect(client.readThreadIds, ['first', 'second']);
      await state.close();
    },
  );

  test(
    'notifications update one session without leaking into another',
    () async {
      final firstClient = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(data: [thread('same')]),
        },
      );
      final secondClient = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(data: [thread('same')]),
        },
      );
      final first = CodexServiceState(
        serverId: 'server',
        connection: firstClient,
      );
      final second = CodexServiceState(
        serverId: 'server',
        connection: secondClient,
      );
      await first.start();
      await second.start();
      await waitFor(
        () =>
            first.catalogPhase == CodexCatalogPhase.ready &&
            second.catalogPhase == CodexCatalogPhase.ready,
      );

      firstClient.emit(
        const CodexThreadStatusChangedNotification2(
          params: CodexThreadStatusChangedNotification(
            threadId: 'same',
            status: CodexActiveThreadStatus(activeFlags: []),
          ),
        ),
      );
      firstClient.emit(
        const CodexThreadNameUpdatedNotification2(
          params: CodexThreadNameUpdatedNotification(
            threadId: 'same',
            threadName: 'Renamed',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(codexThreadIsActive(first.catalog.allThreads.single), isTrue);
      expect(codexThreadTitle(first.catalog.allThreads.single), 'Renamed');
      expect(codexThreadIsActive(second.catalog.allThreads.single), isFalse);
      expect(codexThreadTitle(second.catalog.allThreads.single), 'same');

      firstClient.emit(
        const CodexThreadArchivedNotification2(
          params: CodexThreadArchivedNotification(threadId: 'same'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(first.catalog.allThreads, isEmpty);
      expect(second.catalog.allThreads, hasLength(1));

      await first.close();
      await second.close();
    },
  );

  test('catalog failure can retry without disconnecting', () async {
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [thread('thread')]),
      },
    )..listError = StateError('temporary failure');
    final state = CodexServiceState(serverId: 'server', connection: client);

    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.failed);
    expect(state.catalogError, contains('temporary failure'));
    expect(client.state.phase, CodexConnectionPhase.connected);

    client.listError = null;
    await state.retryCatalog();
    expect(state.catalogPhase, CodexCatalogPhase.ready);
    expect(state.catalog.allThreads.single.id, 'thread');
    await state.close();
  });

  test('forks through a completed turn and selects the new thread', () async {
    final source = thread(
      'source',
      updatedAt: 20,
      turns: const [
        CodexTurn(
          id: 'turn-1',
          items: [CodexAgentMessageThreadItem(id: 'answer', text: 'Done')],
          status: CodexTurnStatus.completed,
        ),
      ],
    );
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(
          data: [
            thread('before', updatedAt: 30),
            source,
            thread('after', updatedAt: 10),
          ],
        ),
      },
    );
    final state = CodexServiceState(serverId: 'server', connection: client);
    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
    await state.readThread(source.id);

    expect(await state.forkThreadAtTurn('turn-1'), isTrue);
    expect(client.forkParams.single.threadId, 'source');
    expect(client.forkParams.single.lastTurnId, 'turn-1');
    expect(state.selectedThread?.id, 'forked-source');
    expect(state.turns.single.id, 'turn-1');
    expect(state.catalog.projects.single.threads.map((thread) => thread.id), [
      'before',
      'forked-source',
      'source',
      'after',
    ]);

    await state.ensureThreadResumedForSend('forked-source');
    expect(client.resumedThreadIds, isEmpty);
    await state.close();
  });

  test('starts a thread in a project and opens it without resume', () async {
    final before = thread('before', updatedAt: 30);
    final current = thread('current', updatedAt: 20);
    final after = thread('after', updatedAt: 10);
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [before, current, after]),
      },
      globalState: jsonEncode({
        'local-projects': {
          'motif': {
            'id': 'motif',
            'name': 'Motif',
            'rootPaths': ['/work/motif'],
          },
        },
        'project-order': ['motif'],
        'pinned-thread-ids': <String>[],
        'projectless-thread-ids': <String>[],
        'thread-project-assignments': {
          'before': {'projectKind': 'local', 'projectId': 'motif'},
          'current': {'projectKind': 'local', 'projectId': 'motif'},
          'after': {'projectKind': 'local', 'projectId': 'motif'},
        },
        'sidebar-project-thread-orders': {
          'motif': {
            'threadIds': ['before', 'current', 'after'],
          },
        },
      }),
    );
    final state = CodexServiceState(serverId: 'server', connection: client);
    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
    await state.readThread('current');
    state
      ..models = const [
        CodexModel(
          defaultReasoningEffort: CodexReasoningEffort('high'),
          description: 'Test',
          displayName: 'Codex Test',
          hidden: false,
          id: 'codex-test',
          isDefault: true,
          model: 'codex-test',
          supportedReasoningEfforts: [],
        ),
      ]
      ..selectedModelId = 'codex-test'
      ..selectedPermissionId = 'full-access';

    expect(
      await state.createThreadForProject(state.catalog.projects.single.project),
      isTrue,
    );
    expect(client.startThreadParams.single.cwd, '/work/motif');
    expect(client.startThreadParams.single.model, 'codex-test');
    expect(client.startThreadParams.single.permissions, 'full-access');
    expect(state.selectedThread?.id, 'new-thread');
    expect(state.catalog.projects.single.threads.map((value) => value.id), [
      'before',
      'new-thread',
      'current',
      'after',
    ]);
    await state.ensureThreadResumedForSend('new-thread');
    expect(client.resumedThreadIds, isEmpty);
    await state.close();
  });

  test(
    'places externally started and refresh-discovered threads before current',
    () async {
      final before = thread('before', updatedAt: 30);
      final current = thread('current', updatedAt: 20);
      final after = thread('after', updatedAt: 10);
      final client = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(data: [before, current, after]),
        },
        globalState: jsonEncode({
          'local-projects': {
            'motif': {
              'id': 'motif',
              'name': 'Motif',
              'rootPaths': ['/work/motif'],
            },
          },
          'project-order': ['motif'],
          'pinned-thread-ids': <String>[],
          'projectless-thread-ids': <String>[],
          'thread-project-assignments': {
            'before': {'projectKind': 'local', 'projectId': 'motif'},
            'current': {'projectKind': 'local', 'projectId': 'motif'},
            'after': {'projectKind': 'local', 'projectId': 'motif'},
          },
          'sidebar-project-thread-orders': {
            'motif': {
              'threadIds': ['before', 'current', 'after'],
            },
          },
        }),
      );
      final state = CodexServiceState(serverId: 'server', connection: client);
      await state.start();
      await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
      await state.readThread('current');

      final external = thread('external', updatedAt: 100);
      client.emit(
        CodexThreadStartedNotification2(
          params: CodexThreadStartedNotification(thread: external),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(state.catalog.projects.single.threads.map((thread) => thread.id), [
        'before',
        'external',
        'current',
        'after',
      ]);

      // A duplicate notification updates the thread but must not place it a
      // second time relative to the current selection.
      client.emit(
        CodexThreadStartedNotification2(
          params: CodexThreadStartedNotification(thread: external),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final refreshed = thread('refreshed', updatedAt: 200);
      client.pages[null] = CodexThreadListResponse(
        data: [refreshed, external, before, current, after],
      );
      await state.refreshCatalog(showLoading: false);
      expect(state.catalog.projects.single.threads.map((thread) => thread.id), [
        'before',
        'external',
        'refreshed',
        'current',
        'after',
      ]);
      await state.close();
    },
  );

  test(
    'hydrates turns and applies live item deltas and plan updates',
    () async {
      final initial = thread('thread');
      final client = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(data: [initial]),
        },
      );
      final state = CodexServiceState(serverId: 'server', connection: client);
      await state.start();
      await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
      await state.readThread('thread');

      client.emit(
        const CodexTurnStartedNotification2(
          params: CodexTurnStartedNotification(
            threadId: 'thread',
            turn: CodexTurn(
              id: 'turn-1',
              items: [],
              status: CodexTurnStatus.inProgress,
            ),
          ),
        ),
      );
      client.emit(
        const CodexItemStartedNotification2(
          params: CodexItemStartedNotification(
            item: CodexAgentMessageThreadItem(id: 'agent-1', text: ''),
            startedAtMs: 1,
            threadId: 'thread',
            turnId: 'turn-1',
          ),
        ),
      );
      client.emit(
        const CodexItemAgentMessageDeltaNotification(
          params: CodexAgentMessageDeltaNotification(
            delta: 'Hello',
            itemId: 'agent-1',
            threadId: 'thread',
            turnId: 'turn-1',
          ),
        ),
      );
      client.emit(
        const CodexTurnPlanUpdatedNotification2(
          params: CodexTurnPlanUpdatedNotification(
            plan: [
              CodexTurnPlanStep(
                status: CodexTurnPlanStepStatus.inProgress,
                step: 'Implement state',
              ),
            ],
            threadId: 'thread',
            turnId: 'turn-1',
          ),
        ),
      );
      client.emit(
        const CodexTurnDiffUpdatedNotification2(
          params: CodexTurnDiffUpdatedNotification(
            diff: 'diff --git a/a b/a\n-old\n+new\n',
            threadId: 'thread',
            turnId: 'turn-1',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(state.activeTurn?.id, 'turn-1');
      expect(
        (state.turns.single.items.single as CodexAgentMessageThreadItem).text,
        'Hello',
      );
      expect(state.activePlan?.plan.single.step, 'Implement state');
      expect(state.activeDiff, contains('+new'));

      client.emit(
        const CodexTurnCompletedNotification2(
          params: CodexTurnCompletedNotification(
            threadId: 'thread',
            // Completed notifications can omit items; streamed items are kept.
            turn: CodexTurn(
              id: 'turn-1',
              items: [],
              status: CodexTurnStatus.completed,
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(state.activeTurn, isNull);
      expect(state.activePlan, isNull);
      expect(state.activeDiff, isNull);
      expect(state.turns.single.items, hasLength(1));
      await state.close();
    },
  );

  test(
    'completed plan items wait for an explicit decision in plan mode',
    () async {
      final initial = thread('thread');
      final client = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(data: [initial]),
        },
      );
      final state = CodexServiceState(serverId: 'server', connection: client);
      await state.start();
      await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
      await state.readThread('thread');
      state.setPlanMode(true);

      client.emit(
        const CodexTurnStartedNotification2(
          params: CodexTurnStartedNotification(
            threadId: 'thread',
            turn: CodexTurn(
              id: 'plan-turn',
              items: [],
              status: CodexTurnStatus.inProgress,
            ),
          ),
        ),
      );
      client.emit(
        const CodexItemCompletedNotification2(
          params: CodexItemCompletedNotification(
            completedAtMs: 1,
            item: CodexPlanThreadItem(id: 'plan-item', text: '# Plan'),
            threadId: 'thread',
            turnId: 'plan-turn',
          ),
        ),
      );
      client.emit(
        const CodexTurnCompletedNotification2(
          params: CodexTurnCompletedNotification(
            threadId: 'thread',
            turn: CodexTurn(
              id: 'plan-turn',
              items: [],
              status: CodexTurnStatus.completed,
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(state.awaitingPlanDecisionItemId, 'plan-item');
      state.skipCurrentPlan();
      expect(state.planModeEnabled, isFalse);
      expect(state.awaitingPlanDecisionItemId, isNull);
      await state.close();
    },
  );

  test(
    'queues during an active turn and can steer the queued message',
    () async {
      final active = thread(
        'thread',
        turns: const [
          CodexTurn(
            id: 'turn-1',
            items: [],
            status: CodexTurnStatus.inProgress,
          ),
        ],
      );
      final client = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(data: [active]),
        },
      );
      final state = CodexServiceState(serverId: 'server', connection: client);
      await state.start();
      await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
      await state.readThread('thread');

      expect(await state.submitMessage('queued', const []), isTrue);
      expect(state.queuedMessages.single.text, 'queued');
      expect(client.resumedThreadIds, ['thread']);

      expect(
        await state.steerQueuedMessage(state.queuedMessages.single.id),
        isTrue,
      );
      expect(state.queuedMessages, isEmpty);
      expect(client.steeredParams.single.expectedTurnId, 'turn-1');
      expect(
        (client.steeredParams.single.input.single as CodexTextUserInput).text,
        'queued',
      );
      await state.close();
    },
  );

  test(
    'starts the next queued message when the active turn completes',
    () async {
      final active = thread(
        'thread',
        turns: const [
          CodexTurn(
            id: 'turn-1',
            items: [],
            status: CodexTurnStatus.inProgress,
          ),
        ],
      );
      final client = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(data: [active]),
        },
      );
      final state = CodexServiceState(serverId: 'server', connection: client);
      await state.start();
      await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
      await state.readThread('thread');
      await state.submitMessage('run next', const []);

      client.emit(
        const CodexTurnCompletedNotification2(
          params: CodexTurnCompletedNotification(
            threadId: 'thread',
            turn: CodexTurn(
              id: 'turn-1',
              items: [],
              status: CodexTurnStatus.completed,
            ),
          ),
        ),
      );
      await waitFor(() => client.startedParams.isNotEmpty);

      expect(state.queuedMessages, isEmpty);
      expect(
        (client.startedParams.single.input.single as CodexTextUserInput).text,
        'run next',
      );
      await state.close();
    },
  );
}

final class FakeCodexClient extends ChangeNotifier
    implements CodexAppServerClient {
  FakeCodexClient({
    required this.pages,
    this.globalState,
    this.models = const [],
  });

  final Map<String?, CodexThreadListResponse> pages;
  final String? globalState;
  final List<CodexModel> models;
  final StreamController<Map<String, Object?>> _raw =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<CodexJsonEncodable> _typed =
      StreamController<CodexJsonEncodable>.broadcast();
  final List<CodexThreadListParams> listParams = [];
  final List<String> readThreadIds = [];
  final List<bool> readIncludeTurns = [];
  final Map<String, Completer<CodexThreadReadResponse>> readGates = {};
  final List<CodexThreadForkParams> forkParams = [];
  final List<CodexThreadStartParams> startThreadParams = [];
  final List<String> resumedThreadIds = [];
  final List<CodexTurnSteerParams> steeredParams = [];
  final List<CodexTurnStartParams> startedParams = [];
  final List<({CodexV2RequestId id, CodexJsonEncodable response})> responses =
      [];
  final List<String> watchedPaths = [];
  final List<String> unwatchedIds = [];
  Object? listError;
  bool closed = false;
  bool disposed = false;

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

  @override
  Future<void> start() async => notifyListeners();

  @override
  Future<void> retry() => start();

  @override
  Future<CodexThreadListResponse> listThreads(
    CodexThreadListParams params,
  ) async {
    listParams.add(params);
    final error = listError;
    if (error != null) throw error;
    return pages[params.cursor] ?? const CodexThreadListResponse(data: []);
  }

  @override
  Future<CodexThreadReadResponse> readThread(
    String threadId, {
    bool includeTurns = false,
  }) async {
    readThreadIds.add(threadId);
    readIncludeTurns.add(includeTurns);
    final gate = readGates[threadId];
    if (gate != null) return gate.future;
    final original = pages.values
        .expand((page) => page.data)
        .firstWhere((thread) => thread.id == threadId);
    return CodexThreadReadResponse(thread: original);
  }

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async {
    forkParams.add(params);
    final source = pages.values
        .expand((page) => page.data)
        .firstWhere((candidate) => candidate.id == params.threadId);
    final fork = thread(
      'forked-${source.id}',
      updatedAt: source.updatedAt,
      turns: source.turns,
    );
    return CodexThreadForkResponse(
      approvalPolicy: const CodexAskForApproval('never'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: fork.cwd,
      model: 'test',
      modelProvider: 'openai',
      sandbox: const CodexDangerFullAccessSandboxPolicy(),
      thread: fork,
    );
  }

  @override
  Future<CodexThreadStartResponse> startThread(
    CodexThreadStartParams params,
  ) async {
    startThreadParams.add(params);
    final created = CodexThread(
      cliVersion: 'test',
      createdAt: 100,
      cwd: CodexV2AbsolutePathBuf(params.cwd ?? ''),
      ephemeral: false,
      id: 'new-thread',
      modelProvider: 'openai',
      name: 'New thread',
      preview: '',
      sessionId: 'new-thread',
      source: const CodexSessionSource('cli'),
      status: const CodexNotLoadedThreadStatus(),
      turns: const [],
      updatedAt: 100,
    );
    return CodexThreadStartResponse(
      approvalPolicy: const CodexAskForApproval('never'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: created.cwd,
      model: params.model ?? 'test',
      modelProvider: 'openai',
      sandbox: const CodexDangerFullAccessSandboxPolicy(),
      thread: created,
    );
  }

  @override
  Future<CodexThreadUnsubscribeResponse> unsubscribeThread(
    String threadId,
  ) async => const CodexThreadUnsubscribeResponse(
    status: CodexThreadUnsubscribeStatus.unsubscribed,
  );

  @override
  Future<CodexThreadResumeResponse> resumeThread(String threadId) async {
    resumedThreadIds.add(threadId);
    final original = pages.values
        .expand((page) => page.data)
        .firstWhere((thread) => thread.id == threadId);
    return CodexThreadResumeResponse(
      approvalPolicy: const CodexAskForApproval('never'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: original.cwd,
      model: 'test',
      modelProvider: 'openai',
      sandbox: const CodexDangerFullAccessSandboxPolicy(),
      thread: original,
    );
  }

  @override
  Future<CodexTurnStartResponse> startTurn(CodexTurnStartParams params) async {
    startedParams.add(params);
    return const CodexTurnStartResponse(
      turn: CodexTurn(
        id: 'turn-new',
        items: [],
        status: CodexTurnStatus.inProgress,
      ),
    );
  }

  @override
  Future<CodexTurnSteerResponse> steerTurn(CodexTurnSteerParams params) async {
    steeredParams.add(params);
    return const CodexTurnSteerResponse(turnId: 'turn-1');
  }

  @override
  Future<CodexTurnInterruptResponse> interruptTurn(
    String threadId,
    String turnId,
  ) async => const CodexTurnInterruptResponse();

  @override
  Future<CodexModelListResponse> listModels(
    CodexModelListParams params,
  ) async => CodexModelListResponse(data: models);

  @override
  Future<CodexPermissionProfileListResponse> listPermissionProfiles(
    CodexPermissionProfileListParams params,
  ) async => const CodexPermissionProfileListResponse(data: []);

  @override
  Future<CodexCollaborationModeListResponse> listCollaborationModes() async =>
      const CodexCollaborationModeListResponse(data: []);

  @override
  Future<CodexSkillsListResponse> listSkills(
    CodexSkillsListParams params,
  ) async => const CodexSkillsListResponse(data: []);

  @override
  Future<CodexPluginListResponse> listPlugins(
    CodexPluginListParams params,
  ) async => const CodexPluginListResponse(marketplaces: []);

  @override
  Future<CodexThreadGoalGetResponse> getThreadGoal(String threadId) async =>
      const CodexThreadGoalGetResponse();

  @override
  Future<CodexThreadGoalSetResponse> setThreadGoal(
    CodexThreadGoalSetParams params,
  ) async => throw StateError('unused');

  @override
  Future<CodexThreadGoalClearResponse> clearThreadGoal(String threadId) async =>
      const CodexThreadGoalClearResponse(cleared: true);

  @override
  Future<CodexFsReadFileResponse> readFile(String path) async {
    if (globalState == null) throw StateError('missing');
    return CodexFsReadFileResponse(
      dataBase64: base64Encode(utf8.encode(globalState!)),
    );
  }

  @override
  Future<CodexFsCreateDirectoryResponse> createDirectory(String path) async =>
      const CodexFsCreateDirectoryResponse();

  @override
  Future<CodexFsWriteFileResponse> writeFile(
    String path,
    String dataBase64,
  ) async => const CodexFsWriteFileResponse();

  @override
  Future<void> respondToServerRequest(
    CodexV2RequestId id,
    CodexJsonEncodable response,
  ) async => responses.add((id: id, response: response));

  @override
  Future<CodexFsWatchResponse> watchFile(String path, String watchId) async {
    watchedPaths.add(path);
    return CodexFsWatchResponse(path: CodexV2AbsolutePathBuf(path));
  }

  @override
  Future<CodexFsUnwatchResponse> unwatchFile(String watchId) async {
    unwatchedIds.add(watchId);
    return const CodexFsUnwatchResponse();
  }

  @override
  Future<void> close() async => closed = true;

  @override
  void dispose() {
    disposed = true;
    unawaited(_raw.close());
    unawaited(_typed.close());
    super.dispose();
  }
}

CodexThread thread(
  String id, {
  int updatedAt = 1,
  bool ephemeral = false,
  List<CodexTurn> turns = const [],
}) => CodexThread(
  cliVersion: 'test',
  createdAt: updatedAt,
  cwd: const CodexV2AbsolutePathBuf('/work/motif'),
  ephemeral: ephemeral,
  id: id,
  modelProvider: 'openai',
  name: id,
  preview: '',
  sessionId: id,
  source: const CodexSessionSource('cli'),
  status: const CodexNotLoadedThreadStatus(),
  turns: turns,
  updatedAt: updatedAt,
);

Future<void> waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was not reached');
}
