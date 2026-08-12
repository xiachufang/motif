import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/codex_service_state.dart';
import 'package:motif/motif/codex/codex_state.dart';
import 'package:motif/motif/codex/codex_thread_catalog.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:motif/motif/ui/screens/codex_thread_sidebar.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('CodexState owns independent in-memory sidebar chrome', () {
    final first = CodexState();
    final second = CodexState();

    expect(first.sidebarMode, CodexSidebarMode.projects);
    expect(first.desktopSidebarVisible, isTrue);
    expect(first.sidebarWidth, 340);
    first
      ..sidebarMode = CodexSidebarMode.timeline
      ..desktopSidebarVisible = false
      ..sidebarWidth = 420;

    expect(second.sidebarMode, CodexSidebarMode.projects);
    expect(second.desktopSidebarVisible, isTrue);
    expect(second.sidebarWidth, 340);
  });

  testWidgets('project hierarchy expands independently and switches timeline', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final threads = <CodexThread>[
      for (var index = 1; index <= 6; index++)
        thread(
          't$index',
          name: 'Thread $index',
          updatedAt: now - index,
          status: index == 1
              ? const CodexActiveThreadStatus(activeFlags: [])
              : const CodexNotLoadedThreadStatus(),
        ),
      thread('p2-thread', name: 'Project two thread', updatedAt: now - 20),
      thread('pin', name: 'Pinned thread', updatedAt: now - 30),
      thread('recent', name: 'Projectless thread', updatedAt: now - 40),
    ];
    final global = CodexGlobalStateData.tryParse(
      jsonEncode({
        'local-projects': {
          for (var index = 1; index <= 7; index++)
            'p$index': {
              'id': 'p$index',
              'name': 'Project $index',
              'rootPaths': ['/work/p$index'],
            },
        },
        'project-order': [for (var index = 1; index <= 7; index++) 'p$index'],
        'pinned-thread-ids': ['pin'],
        'projectless-thread-ids': ['recent'],
        'thread-project-assignments': {
          for (var index = 1; index <= 6; index++)
            't$index': {'projectKind': 'local', 'projectId': 'p1'},
          'p2-thread': {'projectKind': 'local', 'projectId': 'p2'},
          'pin': {'projectKind': 'local', 'projectId': 'p1'},
        },
        'sidebar-project-thread-orders': {
          'p1': {
            'threadIds': [for (var index = 1; index <= 6; index++) 't$index'],
          },
        },
        'selected-project': {'type': 'local', 'projectId': 'p1'},
      }),
    );
    final client = SidebarFakeClient({
      for (final thread in threads) thread.id: thread,
    });
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..catalog = buildCodexCatalog(threads, global)
      ..catalogPhase = CodexCatalogPhase.ready;
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final codexState = CodexState(preferences: preferences);
    final mode = ValueNotifier(CodexSidebarMode.projects);

    Widget buildSidebar(CodexState preferences) => MaterialApp(
      theme: motifTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 340,
          child: ValueListenableBuilder<CodexSidebarMode>(
            valueListenable: mode,
            builder: (context, value, _) => CodexThreadSidebar(
              serviceState: state,
              codexState: preferences,
              mode: value,
              onModeChanged: (next) => mode.value = next,
              onThreadSelected: (threadId) =>
                  unawaited(state.readThread(threadId)),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildSidebar(codexState));

    expect(find.text('Pinned'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Recents'), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-mode-projects')), findsNothing);
    expect(find.byKey(const ValueKey('codex-mode-timeline')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-threads-refresh')), findsOneWidget);
    expect(find.text('Project 7'), findsNothing);
    expect(find.byKey(const ValueKey('codex-thread-t1')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-t5')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-t6')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('codex-project-p1'))).height,
      lessThanOrEqualTo(40),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('codex-thread-t1'))).height,
      lessThanOrEqualTo(32),
    );

    await tester.tap(find.byKey(const ValueKey('codex-projects-more')));
    await tester.pump();
    expect(find.text('Project 7'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('codex-project-threads-more-p1')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('codex-thread-t6')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('codex-project-p2')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('codex-thread-p2-thread')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('codex-thread-t1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('codex-mode-timeline')));
    await tester.pump();
    expect(find.text('Priority'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-t1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('codex-thread-t1')));
    await tester.pump();
    expect(client.readThreadIds, ['t1']);
    expect(client.resumedThreadIds, isEmpty);
    expect(state.selectedThread?.id, 't1');

    await tester.tap(find.byKey(const ValueKey('codex-threads-refresh')));
    await tester.pump();
    expect(client.listThreadCalls, 1);

    await tester.tap(find.byKey(const ValueKey('codex-mode-timeline')));
    await tester.pump();
    expect(mode.value, CodexSidebarMode.projects);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(codexState.flushProjectSidebarPreferences);
    final restoredCodexState = CodexState(preferences: preferences);
    state.catalog = buildCodexCatalog(threads, global);
    await tester.pumpWidget(buildSidebar(restoredCodexState));
    await tester.pump();
    expect(find.text('Project 7'), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-t6')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('codex-thread-p2-thread')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('codex-project-p1')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(restoredCodexState.flushProjectSidebarPreferences);
    final collapsedCodexState = CodexState(preferences: preferences);
    await tester.pumpWidget(buildSidebar(collapsedCodexState));
    await tester.pump();
    expect(find.byKey(const ValueKey('codex-thread-t1')), findsNothing);
    expect(find.text('Project 7'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    mode.dispose();
    state.dispose();
  });

  testWidgets('project action starts and opens a thread in that cwd', (
    tester,
  ) async {
    final project = const CodexLocalProject(
      id: 'p1',
      name: 'Project 1',
      rootPaths: ['/work/p1'],
    );
    final client = SidebarFakeClient({});
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..catalog = CodexCatalogSnapshot(
        allThreads: const [],
        pinnedThreads: const [],
        projects: [CodexProjectGroup(project: project, threads: const [])],
        projectlessThreads: const [],
        pinnedThreadIds: const {},
        projectNamesByThreadId: const {},
        selectedProjectId: 'p1',
        usesGlobalState: true,
      )
      ..catalogPhase = CodexCatalogPhase.ready;

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 340,
            child: CodexThreadSidebar(
              serviceState: state,
              codexState: CodexState(),
              mode: CodexSidebarMode.projects,
              onModeChanged: (_) {},
              onThreadSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('codex-project-new-p1')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(client.startThreadParams.single.cwd, '/work/p1');
    expect(state.selectedThread?.id, 'new-project-thread');
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}

final class SidebarFakeClient extends ChangeNotifier
    implements CodexAppServerClient {
  SidebarFakeClient(this.threads);

  final Map<String, CodexThread> threads;
  final List<String> readThreadIds = [];
  final List<String> resumedThreadIds = [];
  final List<CodexThreadStartParams> startThreadParams = [];
  int listThreadCalls = 0;
  final StreamController<Map<String, Object?>> _raw =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<CodexJsonEncodable> _typed =
      StreamController<CodexJsonEncodable>.broadcast();

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

  @override
  Future<void> start() async {}

  @override
  Future<void> retry() async {}

  @override
  Future<CodexThreadListResponse> listThreads(
    CodexThreadListParams params,
  ) async {
    listThreadCalls++;
    return CodexThreadListResponse(data: threads.values.toList());
  }

  @override
  Future<CodexThreadReadResponse> readThread(
    String threadId, {
    bool includeTurns = false,
  }) async {
    readThreadIds.add(threadId);
    return CodexThreadReadResponse(thread: threads[threadId]!);
  }

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async => throw StateError('unused');

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
      id: 'new-project-thread',
      modelProvider: 'openai',
      name: 'New project thread',
      preview: '',
      sessionId: 'new-project-thread',
      source: const CodexSessionSource('cli'),
      status: const CodexNotLoadedThreadStatus(),
      turns: const [],
      updatedAt: 100,
    );
    threads[created.id] = created;
    return CodexThreadStartResponse(
      approvalPolicy: const CodexAskForApproval('never'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: created.cwd,
      model: 'test',
      modelProvider: 'openai',
      sandbox: const CodexDangerFullAccessSandboxPolicy(),
      thread: created,
    );
  }

  @override
  Future<CodexThreadResumeResponse> resumeThread(String threadId) async {
    resumedThreadIds.add(threadId);
    final thread = threads[threadId]!;
    return CodexThreadResumeResponse(
      approvalPolicy: const CodexAskForApproval('never'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: thread.cwd,
      model: 'test',
      modelProvider: 'openai',
      sandbox: const CodexDangerFullAccessSandboxPolicy(),
      thread: thread,
    );
  }

  @override
  Future<CodexTurnStartResponse> startTurn(CodexTurnStartParams params) async =>
      throw StateError('unused');

  @override
  Future<CodexTurnSteerResponse> steerTurn(CodexTurnSteerParams params) async =>
      throw StateError('unused');

  @override
  Future<CodexTurnInterruptResponse> interruptTurn(
    String threadId,
    String turnId,
  ) async => const CodexTurnInterruptResponse();

  @override
  Future<CodexModelListResponse> listModels(
    CodexModelListParams params,
  ) async => const CodexModelListResponse(data: []);

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
  Future<CodexFsReadFileResponse> readFile(String path) async =>
      throw StateError('unused');

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
  ) async {}

  @override
  Future<CodexFsWatchResponse> watchFile(String path, String watchId) async =>
      throw StateError('unused');

  @override
  Future<CodexFsUnwatchResponse> unwatchFile(String watchId) async =>
      const CodexFsUnwatchResponse();

  @override
  Future<void> close() async {}

  @override
  void dispose() {
    unawaited(_raw.close());
    unawaited(_typed.close());
    super.dispose();
  }
}

CodexThread thread(
  String id, {
  required String name,
  required int updatedAt,
  CodexThreadStatus status = const CodexNotLoadedThreadStatus(),
}) => CodexThread(
  cliVersion: 'test',
  createdAt: updatedAt,
  cwd: const CodexV2AbsolutePathBuf('/work/motif'),
  ephemeral: false,
  id: id,
  modelProvider: 'openai',
  name: name,
  preview: '',
  sessionId: id,
  source: const CodexSessionSource('cli'),
  status: status,
  turns: const [],
  updatedAt: updatedAt,
);
