import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_observation/flutter_observation.dart';
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
      expect(client.watchedPaths, isEmpty);

      await state.readThread('first');
      expect(client.readThreadIds, ['first']);
      expect(client.readIncludeTurns, [false]);
      expect(client.turnListParams, hasLength(1));
      expect(client.turnListParams.single.threadId, 'first');
      expect(client.turnListParams.single.limit, codexThreadTurnsPageSize);
      expect(
        client.turnListParams.single.itemsView?.value,
        codexThreadTurnsItemsView.value,
      );
      expect(
        client.turnListParams.single.sortDirection,
        CodexSortDirection.desc,
      );
      expect(client.resumedThreadIds, isEmpty);
      expect(state.selectedThread?.id, 'first');

      await Future.wait([
        state.ensureThreadResumedForSend('first'),
        state.ensureThreadResumedForSend('first'),
      ]);
      await state.ensureThreadResumedForSend('first');
      expect(client.resumedThreadIds, ['first']);

      final listCallsBeforeChange = client.listParams.length;
      final readsBeforeChange = client.readPaths.length;
      client.globalState = jsonEncode({
        'local-projects': {
          'motif': {
            'id': 'motif',
            'name': 'Motif',
            'rootPaths': ['/work/motif'],
          },
        },
        'project-order': ['motif'],
        'pinned-thread-ids': ['first'],
        'projectless-thread-ids': <String>[],
        'thread-project-assignments': {
          'first': {'projectKind': 'local', 'projectId': 'motif'},
          'second': {'projectKind': 'local', 'projectId': 'motif'},
        },
      });
      client.emit(
        const CodexFsChangedNotification2(
          params: CodexFsChangedNotification(
            changedPaths: [],
            watchId: 'unrelated-watch',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 260));
      expect(client.listParams, hasLength(listCallsBeforeChange));
      expect(client.readPaths, hasLength(readsBeforeChange));
      expect(state.catalog.pinnedThreads.single.id, 'second');

      await state.refreshCatalog(showLoading: false);
      expect(client.listParams.length, greaterThan(listCallsBeforeChange));
      expect(client.readPaths.length, greaterThan(readsBeforeChange));
      expect(state.catalog.pinnedThreads.single.id, 'first');

      await state.close();
      expect(client.unwatchedIds, isEmpty);
      expect(client.closed, isTrue);
      expect(client.disposed, isTrue);
    },
  );

  test(
    'reconnect re-reads an unsubscribed selected thread and catches up turns',
    () async {
      final beforeDisconnect = thread(
        'thread',
        turns: const [
          CodexTurn(
            id: 'turn-1',
            items: [
              CodexAgentMessageThreadItem(id: 'answer-1', text: 'Before'),
            ],
            status: CodexTurnStatus.completed,
          ),
        ],
      );
      final client = FakeCodexClient(
        pages: {
          null: CodexThreadListResponse(data: [beforeDisconnect]),
        },
      );
      final state = CodexServiceState(serverId: 'server', connection: client);

      await state.start();
      await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
      await state.readThread('thread');

      client.setConnectionState(
        const CodexConnectionState(
          phase: CodexConnectionPhase.failed,
          error: 'socket closed while backgrounded',
        ),
      );
      final afterReconnect = thread(
        'thread',
        updatedAt: 2,
        turns: const [
          CodexTurn(
            id: 'turn-1',
            items: [
              CodexAgentMessageThreadItem(id: 'answer-1', text: 'Before'),
            ],
            status: CodexTurnStatus.completed,
          ),
          CodexTurn(
            id: 'turn-2',
            items: [
              CodexAgentMessageThreadItem(
                id: 'answer-2',
                text: 'While backgrounded',
              ),
            ],
            status: CodexTurnStatus.completed,
          ),
        ],
      );
      client.pages[null] = CodexThreadListResponse(data: [afterReconnect]);
      client.setConnectionState(
        const CodexConnectionState(
          phase: CodexConnectionPhase.connected,
          response: CodexInitializeResponse(
            codexHome: CodexV2AbsolutePathBuf('/tmp/codex'),
            platformFamily: 'unix',
            platformOs: 'macos',
            userAgent: 'test-reconnected',
          ),
        ),
      );

      await waitFor(() => state.turns.length == 2);
      expect(client.resumedThreadIds, isEmpty);
      expect(client.readThreadIds, ['thread', 'thread']);
      expect(client.turnListParams, hasLength(2));
      expect(
        (state.turns.last.items.single as CodexAgentMessageThreadItem).text,
        'While backgrounded',
      );

      await state.ensureThreadResumedForSend('thread');
      expect(client.resumedThreadIds, ['thread']);
      await state.close();
    },
  );

  test('keeps active hidden sessions and evicts completed ones', () async {
    final first = thread('first', updatedAt: 20);
    final second = thread('second', updatedAt: 10);
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [first, second]),
      },
    );
    final state = CodexServiceState(serverId: 'server', connection: client);

    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
    await state.readThread('first');
    client.emit(
      const CodexTurnStartedNotification2(
        params: CodexTurnStartedNotification(
          threadId: 'first',
          turn: CodexTurn(
            id: 'active-turn',
            items: [],
            status: CodexTurnStatus.inProgress,
          ),
        ),
      ),
    );
    await waitFor(
      () => state.conversations.sessionFor('first')?.activeTurn != null,
    );

    await state.readThread('second');
    await state.conversations.evictIdleSessions(force: true);
    expect(state.conversations.sessionFor('first'), isNotNull);

    client.emit(
      const CodexTurnCompletedNotification2(
        params: CodexTurnCompletedNotification(
          threadId: 'first',
          turn: CodexTurn(
            id: 'active-turn',
            items: [],
            status: CodexTurnStatus.completed,
          ),
        ),
      ),
    );
    await waitFor(
      () => state.conversations.sessionFor('first')?.activeTurn == null,
    );
    await state.conversations.evictIdleSessions(force: true);
    expect(state.conversations.sessionFor('first'), isNull);
    expect(state.conversations.idleRetention, const Duration(minutes: 5));
    await state.close();
  });

  test('recreates an evicted subscribed session when a turn starts', () async {
    final first = thread('first', updatedAt: 20);
    final second = thread('second', updatedAt: 10);
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [first, second]),
      },
    );
    final state = CodexServiceState(serverId: 'server', connection: client);

    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
    await state.readThread('first');
    await state.ensureThreadResumedForSend('first');
    await state.readThread('second');
    await state.conversations.evictIdleSessions(force: true);
    expect(state.conversations.sessionFor('first'), isNull);

    client.emit(
      const CodexTurnStartedNotification2(
        params: CodexTurnStartedNotification(
          threadId: 'first',
          turn: CodexTurn(
            id: 'background-turn',
            items: [],
            status: CodexTurnStatus.inProgress,
          ),
        ),
      ),
    );
    await waitFor(
      () =>
          state.conversations.sessionFor('first')?.activeTurn?.id ==
          'background-turn',
    );

    expect(client.resumedThreadIds, ['first']);
    expect(client.readThreadIds.where((id) => id == 'first'), hasLength(2));
    await state.close();
  });

  test('loads recent turns first and prepends older cursor pages', () async {
    const oldest = CodexTurn(
      id: 'turn-1',
      items: [],
      status: CodexTurnStatus.completed,
    );
    const older = CodexTurn(
      id: 'turn-2',
      items: [],
      status: CodexTurnStatus.completed,
    );
    const recent = CodexTurn(
      id: 'turn-3',
      items: [],
      status: CodexTurnStatus.completed,
    );
    const latest = CodexTurn(
      id: 'turn-4',
      items: [],
      status: CodexTurnStatus.completed,
    );
    final existing = thread('thread');
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [existing]),
      },
      turnPages: const {
        'thread': {
          null: CodexThreadTurnsListResponse(
            data: [latest, recent],
            nextCursor: 'older-page',
          ),
          'older-page': CodexThreadTurnsListResponse(
            data: [recent, older, oldest],
          ),
        },
      },
    );
    final state = CodexServiceState(serverId: 'server', connection: client);

    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
    await state.readThread('thread');

    expect(state.turns.map((turn) => turn.id), ['turn-3', 'turn-4']);
    expect(state.hasOlderTurns, isTrue);

    expect(await state.loadOlderTurns(), isTrue);
    expect(state.turns.map((turn) => turn.id), [
      'turn-1',
      'turn-2',
      'turn-3',
      'turn-4',
    ]);
    expect(state.hasOlderTurns, isFalse);
    expect(client.turnListParams.map((params) => params.cursor), [
      null,
      'older-page',
    ]);

    await state.close();
  });

  test('manages threads through app-server APIs', () async {
    final original = thread('managed', updatedAt: 10);
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [original]),
      },
    );
    final state = CodexServiceState(serverId: 'server', connection: client);

    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);

    final searchResults = await state.listThreadsForManagement(
      archived: true,
      searchTerm: 'managed',
    );
    expect(searchResults.single.id, 'managed');
    expect(client.listParams.last.archived, isTrue);
    expect(client.listParams.last.searchTerm, 'managed');

    await state.renameThread('managed', 'Renamed');
    expect(client.renamedThreads.single, (
      threadId: 'managed',
      name: 'Renamed',
    ));
    expect(codexThreadTitle(state.catalog.allThreads.single), 'Renamed');

    client.emit(
      const CodexThreadClosedNotification2(
        params: CodexThreadClosedNotification(threadId: 'managed'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(state.catalog.allThreads.single.id, 'managed');

    await state.archiveThread('managed');
    expect(client.archivedThreadIds, ['managed']);
    expect(state.catalog.allThreads, isEmpty);

    client.unarchiveResult = codexThreadWithName(original, 'Renamed');
    await state.unarchiveThread('managed');
    expect(client.unarchivedThreadIds, ['managed']);
    expect(codexThreadTitle(state.catalog.allThreads.single), 'Renamed');

    await state.deleteThread('managed');
    expect(client.deletedThreadIds, ['managed']);
    expect(state.catalog.allThreads, isEmpty);

    await state.close();
  });

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

  test('restores a reasoning effort preference in a hydrated thread', () async {
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
          supportedReasoningEfforts: [
            CodexReasoningEffortOption(
              description: 'Medium',
              reasoningEffort: CodexReasoningEffort('medium'),
            ),
            CodexReasoningEffortOption(
              description: 'Extra high',
              reasoningEffort: CodexReasoningEffort('xhigh'),
            ),
          ],
        ),
      ],
    );
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..configureReasoningEffortPreference(preferredReasoningEffort: 'xhigh');

    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
    await state.readThread('thread');
    await waitFor(() => state.selectedConversation?.models.isNotEmpty == true);

    expect(state.selectedConversation?.selectedReasoningEffort, 'xhigh');
    expect(state.selectedReasoningEffort, 'xhigh');
    await state.close();
  });

  test('records reasoning effort restored by a lazy thread resume', () async {
    final existing = thread('thread');
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [existing]),
      },
      resumeReasoningEffort: const CodexReasoningEffort('xhigh'),
    );
    final recorded = <String?>[];
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..configureReasoningEffortPreference(onSelected: recorded.add);

    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
    await state.readThread('thread');
    expect(recorded, isEmpty);

    await state.ensureThreadResumedForSend('thread');

    expect(state.selectedReasoningEffort, 'xhigh');
    expect(recorded, ['xhigh']);
    await state.close();
  });

  test('restores and records a permission preference', () async {
    final existing = thread('thread');
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [existing]),
      },
      permissionProfiles: const [
        CodexPermissionProfileSummary(
          allowed: true,
          description: 'Full access',
          id: 'full-access',
        ),
      ],
    );
    final recorded = <String?>[];
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..configurePermissionPreference(
        hasPreference: true,
        preferredPermissionId: 'full-access',
        onSelected: recorded.add,
      );

    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
    await state.readThread('thread');
    await waitFor(() => state.permissionProfiles.isNotEmpty);
    expect(state.selectedPermissionId, 'full-access');
    expect(recorded, isEmpty);

    state.selectPermissionProfile(null);
    expect(recorded, [isNull]);
    expect(state.selectedPermissionId, isNull);
    await state.close();
  });

  test('clears a permission preference that is no longer available', () async {
    final client = FakeCodexClient(
      pages: {
        null: CodexThreadListResponse(data: [thread('thread')]),
      },
      permissionProfiles: const [
        CodexPermissionProfileSummary(
          allowed: true,
          description: 'Default access',
          id: 'default-access',
        ),
      ],
    );
    var invalidated = 0;
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..configurePermissionPreference(
        hasPreference: true,
        preferredPermissionId: 'removed-access',
        onInvalidated: () => invalidated++,
      );

    await state.start();
    await waitFor(() => state.catalogPhase == CodexCatalogPhase.ready);
    await state.readThread('thread');
    await waitFor(() => state.permissionProfiles.isNotEmpty);
    expect(state.selectedPermissionId, isNull);
    expect(invalidated, 1);
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

    expect(
      await state.selectedConversation!.forkThreadAtTurn('turn-1'),
      isTrue,
    );
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
      ..configurePermissionPreference(
        hasPreference: true,
        preferredPermissionId: 'full-access',
      );

    expect(
      await state.createThreadForProject(state.catalog.projects.single.project),
      isTrue,
    );
    expect(client.startThreadParams.single.cwd, '/work/motif');
    expect(client.startThreadParams.single.model, 'codex-test');
    expect(client.startThreadParams.single.permissions, 'full-access');
    expect(state.selectedThread?.id, 'new-thread');
    expect(state.catalog.projects.single.threads.map((value) => value.id), [
      'new-thread',
      'before',
      'current',
      'after',
    ]);
    await state.ensureThreadResumedForSend('new-thread');
    expect(client.resumedThreadIds, isEmpty);

    expect(codexThreadTitle(state.selectedThread!), 'Untitled thread');
    expect(
      await state.submitMessage(
        'Fix observer race\nwith a regression test',
        const [],
      ),
      isTrue,
    );
    expect(codexThreadTitle(state.selectedThread!), 'Fix observer race');
    expect(
      codexThreadTitle(state.catalog.projects.single.threads.first),
      'Fix observer race',
    );

    client.emit(
      const CodexThreadNameUpdatedNotification2(
        params: CodexThreadNameUpdatedNotification(
          threadId: 'new-thread',
          threadName: 'Observer rollout fix',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(codexThreadTitle(state.selectedThread!), 'Observer rollout fix');
    expect(
      codexThreadTitle(state.catalog.projects.single.threads.first),
      'Observer rollout fix',
    );
    await state.close();
  });

  test(
    'sorts externally started and refresh-discovered project threads by recency',
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
        'external',
        'before',
        'current',
        'after',
      ]);

      // A duplicate notification updates the thread without duplicating it.
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
        'refreshed',
        'external',
        'before',
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

  test('coalesces burst deltas into one observable item update', () async {
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
    await Future<void>.delayed(Duration.zero);

    final item = state.viewModel.turns.single.items.single;
    var itemUpdates = 0;
    final subscription = observe(
      () => item.item,
      onChange: (_) => itemUpdates++,
      scheduler: ObservationSchedulers.immediate,
    );
    for (var index = 0; index < 100; index++) {
      client.emit(
        const CodexItemAgentMessageDeltaNotification(
          params: CodexAgentMessageDeltaNotification(
            delta: 'x',
            itemId: 'agent-1',
            threadId: 'thread',
            turnId: 'turn-1',
          ),
        ),
      );
    }
    await Future<void>.delayed(
      CodexConversationState.deltaFlushInterval +
          const Duration(milliseconds: 20),
    );

    expect(
      (state.turns.single.items.single as CodexAgentMessageThreadItem).text,
      List.filled(100, 'x').join(),
    );
    expect(itemUpdates, 1);
    expect(item.streaming, isTrue);

    subscription.dispose();
    await state.close();
  });

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
    'queues during an active turn and shows steer before confirmation',
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
      state.setQueueing(true);

      expect(await state.submitMessage('queued', const []), isTrue);
      expect(state.queuedMessages.single.text, 'queued');
      expect(client.resumedThreadIds, ['thread']);

      final steerGate = Completer<CodexTurnSteerResponse>();
      client.steerGate = steerGate;
      final steer = state.steerQueuedMessage(state.queuedMessages.single.id);
      await waitFor(() => client.steeredParams.isNotEmpty);

      final params = client.steeredParams.single;
      final clientId = params.clientUserMessageId;
      expect(clientId, isNotNull);
      final optimistic = state.activeTurn!.items
          .whereType<CodexUserMessageThreadItem>()
          .single;
      expect(optimistic.clientId, clientId);
      expect((optimistic.content.single as CodexTextUserInput).text, 'queued');
      expect(state.queuedMessages, hasLength(1));

      client.emit(
        CodexItemStartedNotification2(
          params: CodexItemStartedNotification(
            item: CodexUserMessageThreadItem(
              clientId: clientId,
              content: const [CodexTextUserInput(text: 'queued')],
              id: 'server-user-message',
            ),
            startedAtMs: 1,
            threadId: 'thread',
            turnId: 'turn-1',
          ),
        ),
      );
      await waitFor(
        () =>
            state.activeTurn!.items
                .whereType<CodexUserMessageThreadItem>()
                .single
                .id ==
            'server-user-message',
      );
      expect(
        state.activeTurn!.items.whereType<CodexUserMessageThreadItem>(),
        hasLength(1),
      );

      steerGate.complete(const CodexTurnSteerResponse(turnId: 'turn-1'));
      expect(await steer, isTrue);
      expect(state.queuedMessages, isEmpty);
      expect(params.expectedTurnId, 'turn-1');
      expect((params.input.single as CodexTextUserInput).text, 'queued');
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
      state.setQueueing(true);
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
    this.turnPages = const {},
    this.globalState,
    this.models = const [],
    this.permissionProfiles = const [],
    this.resumeReasoningEffort,
  });

  final Map<String?, CodexThreadListResponse> pages;
  final Map<String, Map<String?, CodexThreadTurnsListResponse>> turnPages;
  String? globalState;
  final List<CodexModel> models;
  final List<CodexPermissionProfileSummary> permissionProfiles;
  final CodexReasoningEffort? resumeReasoningEffort;
  final StreamController<Map<String, Object?>> _raw =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<CodexJsonEncodable> _typed =
      StreamController<CodexJsonEncodable>.broadcast();
  final List<CodexThreadListParams> listParams = [];
  final List<({String threadId, String name})> renamedThreads = [];
  final List<String> archivedThreadIds = [];
  final List<String> unarchivedThreadIds = [];
  final List<String> deletedThreadIds = [];
  CodexThread? unarchiveResult;
  final List<String> readThreadIds = [];
  final List<bool> readIncludeTurns = [];
  final List<CodexThreadTurnsListParams> turnListParams = [];
  final Map<String, Completer<CodexThreadReadResponse>> readGates = {};
  final List<CodexThreadForkParams> forkParams = [];
  final List<CodexThreadStartParams> startThreadParams = [];
  final List<String> resumedThreadIds = [];
  final List<bool> resumeIncludeTurns = [];
  final List<CodexThreadResumeInitialTurnsPageParams?> resumeInitialTurnsPages =
      [];
  final List<CodexTurnSteerParams> steeredParams = [];
  final List<CodexTurnStartParams> startedParams = [];
  final List<({CodexV2RequestId id, CodexJsonEncodable response})> responses =
      [];
  final List<String> watchedPaths = [];
  final List<String> readPaths = [];
  final List<String> unwatchedIds = [];
  Object? listError;
  Completer<CodexTurnSteerResponse>? steerGate;
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

  void setConnectionState(CodexConnectionState value) {
    state = value;
    notifyListeners();
  }

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
  Future<CodexThreadSetNameResponse> setThreadName(
    String threadId,
    String name,
  ) async {
    renamedThreads.add((threadId: threadId, name: name));
    return const CodexThreadSetNameResponse();
  }

  @override
  Future<CodexThreadArchiveResponse> archiveThread(String threadId) async {
    archivedThreadIds.add(threadId);
    return const CodexThreadArchiveResponse();
  }

  @override
  Future<CodexThreadUnarchiveResponse> unarchiveThread(String threadId) async {
    unarchivedThreadIds.add(threadId);
    final restored = unarchiveResult;
    if (restored == null) throw StateError('Missing unarchive result');
    return CodexThreadUnarchiveResponse(thread: restored);
  }

  @override
  Future<CodexThreadDeleteResponse> deleteThread(String threadId) async {
    deletedThreadIds.add(threadId);
    return const CodexThreadDeleteResponse();
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
  Future<CodexThreadTurnsListResponse> listThreadTurns(
    CodexThreadTurnsListParams params,
  ) async {
    turnListParams.add(params);
    final configured = turnPages[params.threadId]?[params.cursor];
    if (configured != null) return configured;
    final original = pages.values
        .expand((page) => page.data)
        .firstWhere((thread) => thread.id == params.threadId);
    return CodexThreadTurnsListResponse(
      data: original.turns.reversed.toList(growable: false),
    );
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
      name: null,
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
  Future<CodexThreadResumeResponse> resumeThread(
    String threadId, {
    bool includeTurns = false,
    CodexThreadResumeInitialTurnsPageParams? initialTurnsPage,
  }) async {
    resumedThreadIds.add(threadId);
    resumeIncludeTurns.add(includeTurns);
    resumeInitialTurnsPages.add(initialTurnsPage);
    final original = pages.values
        .expand((page) => page.data)
        .firstWhere((thread) => thread.id == threadId);
    return CodexThreadResumeResponse(
      approvalPolicy: const CodexAskForApproval('never'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: original.cwd,
      model: 'test',
      modelProvider: 'openai',
      reasoningEffort: resumeReasoningEffort,
      initialTurnsPage: initialTurnsPage == null
          ? null
          : CodexTurnsPage(
              data: original.turns.reversed.toList(growable: false),
            ),
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
    final gate = steerGate;
    if (gate != null) return gate.future;
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
  ) async => CodexPermissionProfileListResponse(data: permissionProfiles);

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
    readPaths.add(path);
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
