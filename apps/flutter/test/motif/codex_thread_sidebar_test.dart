import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/codex_service_state.dart';
import 'package:motif/motif/codex/codex_state.dart';
import 'package:motif/motif/codex/codex_thread_catalog.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:motif/motif/ui/screens/codex_thread_sidebar.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/codex_sidebar_components.dart';
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

  test('CodexState keeps sidebar scroll positions per server and mode', () {
    final state = CodexState();

    state
      ..setSidebarScrollOffset('server-1', CodexSidebarMode.projects, 120)
      ..setSidebarScrollOffset('server-1', CodexSidebarMode.timeline, 240)
      ..setSidebarScrollOffset('server-2', CodexSidebarMode.projects, 360);

    expect(
      state.sidebarScrollOffset('server-1', CodexSidebarMode.projects),
      120,
    );
    expect(
      state.sidebarScrollOffset('server-1', CodexSidebarMode.timeline),
      240,
    );
    expect(
      state.sidebarScrollOffset('server-2', CodexSidebarMode.projects),
      360,
    );
    state.setSidebarScrollOffset(
      'server-1',
      CodexSidebarMode.projects,
      double.nan,
    );
    expect(state.sidebarScrollOffset('server-1', CodexSidebarMode.projects), 0);
  });

  test('CodexState persists selected models per server', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final state = CodexState(preferences: preferences);

    state
      ..setSelectedModelId('server-1', 'gpt-5.4')
      ..setSelectedModelId('server-2', 'gpt-5.6');
    await state.flushSelectedModelPreferences();

    final restored = CodexState(preferences: preferences);
    expect(restored.selectedModelId('server-1'), 'gpt-5.4');
    expect(restored.selectedModelId('server-2'), 'gpt-5.6');

    restored.setSelectedModelId('server-1', null);
    await restored.flushSelectedModelPreferences();
    final cleared = CodexState(preferences: preferences);
    expect(cleared.selectedModelId('server-1'), isNull);
    expect(cleared.selectedModelId('server-2'), 'gpt-5.6');
  });

  test('CodexState persists the last opened thread per server', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final state = CodexState(preferences: preferences);

    state
      ..setLastOpenedThreadId('server-1', 'thread-1')
      ..setLastOpenedThreadId('server-2', 'thread-2');
    await state.flushLastOpenedThreadPreferences();

    final restored = CodexState(preferences: preferences);
    expect(restored.lastOpenedThreadId('server-1'), 'thread-1');
    expect(restored.lastOpenedThreadId('server-2'), 'thread-2');

    restored.setLastOpenedThreadId('server-1', null);
    await restored.flushLastOpenedThreadPreferences();
    final cleared = CodexState(preferences: preferences);
    expect(cleared.lastOpenedThreadId('server-1'), isNull);
    expect(cleared.lastOpenedThreadId('server-2'), 'thread-2');
  });

  test('CodexState persists permission choices per server', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final state = CodexState(preferences: preferences);

    state
      ..setSelectedPermissionId('server-1', 'full-access')
      ..setSelectedPermissionId('server-2', null);
    await state.flushSelectedPermissionPreferences();

    final restored = CodexState(preferences: preferences);
    expect(restored.hasSelectedPermissionPreference('server-1'), isTrue);
    expect(restored.selectedPermissionId('server-1'), 'full-access');
    expect(restored.hasSelectedPermissionPreference('server-2'), isTrue);
    expect(restored.selectedPermissionId('server-2'), isNull);

    restored.clearSelectedPermissionId('server-2');
    await restored.flushSelectedPermissionPreferences();
    final cleared = CodexState(preferences: preferences);
    expect(cleared.hasSelectedPermissionPreference('server-2'), isFalse);
  });

  test('CodexState persists Side Chat indexes per parent thread', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final state = CodexState(preferences: preferences);

    state
      ..setSideChatIndex(
        'server-1',
        'parent-1',
        threadIds: const ['side-1', 'side-2'],
        selectedThreadId: 'side-1',
      )
      ..setSideChatIndex(
        'server-1',
        'parent-2',
        threadIds: const ['side-3'],
        selectedThreadId: 'side-3',
      );
    await state.flushSideChatIndexes();

    final restored = CodexState(preferences: preferences);
    expect(restored.sideChatIndex('server-1', 'parent-1').threadIds, [
      'side-1',
      'side-2',
    ]);
    expect(
      restored.sideChatIndex('server-1', 'parent-1').selectedThreadId,
      'side-1',
    );
    expect(restored.sideChatIndex('server-1', 'parent-2').threadIds, [
      'side-3',
    ]);

    restored.setSideChatIndex('server-1', 'parent-1', threadIds: const []);
    await restored.flushSideChatIndexes();
    final cleared = CodexState(preferences: preferences);
    expect(cleared.sideChatIndex('server-1', 'parent-1').threadIds, isEmpty);
    expect(cleared.sideChatIndex('server-1', 'parent-2').threadIds, ['side-3']);
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
      for (var index = 1; index <= 26; index++)
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
          for (var index = 1; index <= 26; index++)
            't$index': {'projectKind': 'local', 'projectId': 'p1'},
          'p2-thread': {'projectKind': 'local', 'projectId': 'p2'},
          'pin': {'projectKind': 'local', 'projectId': 'p1'},
        },
        'sidebar-project-thread-orders': {
          'p1': {
            'threadIds': [for (var index = 1; index <= 26; index++) 't$index'],
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
    expect(
      tester.getCenter(find.text('Threads')).dx,
      lessThan(
        tester.getCenter(find.byKey(const ValueKey('codex-mode-timeline'))).dx,
      ),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('codex-mode-timeline'))).dx,
      lessThan(
        tester
            .getCenter(find.byKey(const ValueKey('codex-threads-refresh')))
            .dx,
      ),
    );
    expect(find.text('Project 7'), findsNothing);
    expect(find.byKey(const ValueKey('codex-thread-t1')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-t5')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-t6')), findsNothing);
    final projectThreadsMore = find.byKey(
      const ValueKey('codex-project-threads-more-p1'),
    );
    expect(
      tester
          .getTopLeft(
            find.descendant(
              of: projectThreadsMore,
              matching: find.text('Show more'),
            ),
          )
          .dx,
      tester
          .getTopLeft(
            find.descendant(
              of: find.byKey(const ValueKey('codex-thread-t1')),
              matching: find.text('Thread 1'),
            ),
          )
          .dx,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('codex-project-p1'))).height,
      codexSidebarRowHeight,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('codex-thread-t1'))).height,
      codexSidebarRowHeight,
    );
    final projectToggle = find.byKey(const ValueKey('codex-project-toggle-p1'));
    final threadActionsIcon = find.descendant(
      of: find.byKey(const ValueKey('codex-thread-actions-t1')),
      matching: find.byIcon(Icons.more_horiz),
    );
    expect(
      tester.getTopRight(threadActionsIcon).dx,
      closeTo(
        tester.getCenter(projectToggle).dx +
            tester.getSize(projectToggle).width / 2,
        0.01,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('codex-projects-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Project 7'), findsOneWidget);

    await tester.ensureVisible(projectThreadsMore);
    await tester.tap(projectThreadsMore);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('codex-thread-t15')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-t16')), findsNothing);
    expect(
      find.descendant(of: projectThreadsMore, matching: find.text('Show more')),
      findsOneWidget,
    );

    await tester.ensureVisible(projectThreadsMore);
    await tester.tap(projectThreadsMore);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('codex-thread-t25')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-t26')), findsNothing);
    expect(
      find.descendant(of: projectThreadsMore, matching: find.text('Show more')),
      findsOneWidget,
    );

    await tester.ensureVisible(projectThreadsMore);
    await tester.tap(projectThreadsMore);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('codex-thread-t26')), findsOneWidget);
    expect(
      find.descendant(of: projectThreadsMore, matching: find.text('Show less')),
      findsOneWidget,
    );

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
    expect(find.byKey(const ValueKey('codex-thread-t26')), findsOneWidget);
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

    await tester.tap(find.byKey(const ValueKey('codex-project-p1')));
    await tester.pump();
    expect(find.byKey(const ValueKey('codex-thread-t5')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-t6')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('codex-project-threads-more-p1')),
        matching: find.text('Show more'),
      ),
      findsOneWidget,
    );

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
    var createdThreads = 0;
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
              onThreadCreated: () => createdThreads++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('codex-project-new-p1')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(client.startThreadParams.single.cwd, '/work/p1');
    expect(state.selectedThread?.id, 'new-project-thread');
    expect(createdThreads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('project action loading indicator is vertically centered', (
    tester,
  ) async {
    const project = CodexLocalProject(
      id: 'p1',
      name: 'Project 1',
      rootPaths: ['/work/p1'],
    );
    final state =
        CodexServiceState(serverId: 'server', connection: SidebarFakeClient({}))
          ..catalog = const CodexCatalogSnapshot(
            allThreads: [],
            pinnedThreads: [],
            projects: [CodexProjectGroup(project: project, threads: [])],
            projectlessThreads: [],
            pinnedThreadIds: {},
            projectNamesByThreadId: {},
            selectedProjectId: 'p1',
            usesGlobalState: true,
          )
          ..catalogPhase = CodexCatalogPhase.ready
          ..creatingProjectId = 'p1';

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

    final row = find.byKey(const ValueKey('codex-project-p1'));
    final loading = find.byKey(const ValueKey('codex-project-new-loading-p1'));
    expect(loading, findsOneWidget);
    expect(tester.getCenter(loading).dy, tester.getCenter(row).dy);
    expect(tester.getSize(loading), const Size.square(16));
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('Recents action starts and opens a projectless thread', (
    tester,
  ) async {
    final client = SidebarFakeClient({});
    var createdThreads = 0;
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..catalog = const CodexCatalogSnapshot.empty()
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
              onThreadCreated: () => createdThreads++,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Recents'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('codex-recents-new')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(client.startThreadParams.single.cwd, isNull);
    expect(state.selectedThread?.id, 'new-projectless-thread');
    expect(createdThreads, 1);
    expect(
      state.catalog.projectlessThreads.single.id,
      'new-projectless-thread',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('searches and manages active and archived threads', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final active = thread('managed', name: 'Managed thread', updatedAt: 20);
    final client = SidebarFakeClient({'managed': active});
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..catalog = buildCodexCatalog([active], null)
      ..catalogPhase = CodexCatalogPhase.ready;
    await state.refreshCatalog();

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 340,
            child: CodexThreadSidebar(
              serviceState: state,
              codexState: CodexState(),
              mode: CodexSidebarMode.timeline,
              onModeChanged: (_) {},
              onThreadSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('codex-thread-actions-managed')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('codex-thread-rename-field')),
      'Renamed thread',
    );
    await tester.tap(find.byKey(const ValueKey('codex-thread-rename-save')));
    await tester.pumpAndSettle();
    expect(find.text('Renamed thread'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('codex-threads-search')));
    await tester.pump();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('codex-thread-search-field')),
        matching: find.byType(TextField),
      ),
      'Renamed',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(client.listParams.last.archived, isFalse);
    expect(client.listParams.last.searchTerm, 'Renamed');
    expect(
      find.byKey(const ValueKey('codex-thread-search-results')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('codex-threads-search')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('codex-thread-actions-managed')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(client.threads, isEmpty);
    expect(client.archivedThreads, contains('managed'));

    await tester.tap(find.byKey(const ValueKey('codex-threads-archived')));
    await tester.pumpAndSettle();
    expect(client.listParams.last.archived, isTrue);
    expect(
      find.byKey(const ValueKey('codex-archived-thread-list')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('codex-thread-actions-managed')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete permanently'), findsNothing);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(client.archivedThreads, isEmpty);
    expect(client.threads, contains('managed'));
    expect(find.text('No archived threads'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('codex-threads-archived')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('codex-thread-actions-managed')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete permanently'), findsNothing);
    expect(client.threads, contains('managed'));

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('shows a worktree icon in the right-side status area', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final worktree = thread(
      'worktree',
      name: 'Worktree thread',
      updatedAt: 20,
      cwd: '/tmp/codex/worktrees/a1b2/motif',
    );
    final checkout = thread(
      'checkout',
      name: 'Checkout thread',
      updatedAt: 10,
      cwd: '/work/motif',
    );
    final client = SidebarFakeClient({
      worktree.id: worktree,
      checkout.id: checkout,
    });
    final state = CodexServiceState(serverId: 'server', connection: client)
      ..catalog = buildCodexCatalog([worktree, checkout], null)
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
              mode: CodexSidebarMode.timeline,
              onModeChanged: (_) {},
              onThreadSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    final icon = find.byKey(const ValueKey('codex-thread-worktree-worktree'));
    expect(icon, findsOneWidget);
    expect(
      find.byKey(const ValueKey('codex-thread-worktree-checkout')),
      findsNothing,
    );
    expect(
      tester.getCenter(find.text('Worktree thread')).dx,
      lessThan(tester.getCenter(icon).dx),
    );
    expect(
      tester.getTopLeft(icon).dx -
          tester.getTopRight(find.text('Worktree thread')).dx,
      greaterThan(MotifSpacing.lg),
    );
    expect(
      tester.getCenter(icon).dx,
      lessThan(
        tester
            .getCenter(
              find.byKey(const ValueKey('codex-thread-actions-worktree')),
            )
            .dx,
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}

final class SidebarFakeClient extends ChangeNotifier
    implements CodexAppServerClient {
  SidebarFakeClient(this.threads, {Map<String, CodexThread>? archivedThreads})
    : archivedThreads = archivedThreads ?? {};

  final Map<String, CodexThread> threads;
  final Map<String, CodexThread> archivedThreads;
  final List<String> readThreadIds = [];
  final List<String> resumedThreadIds = [];
  final List<CodexThreadStartParams> startThreadParams = [];
  final List<CodexThreadListParams> listParams = [];
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
    listParams.add(params);
    final source = params.archived == true ? archivedThreads : threads;
    final searchTerm = params.searchTerm;
    final data = source.values
        .where(
          (thread) =>
              searchTerm == null ||
              codexThreadTitle(thread).contains(searchTerm),
        )
        .toList();
    return CodexThreadListResponse(data: data);
  }

  @override
  Future<CodexThreadSetNameResponse> setThreadName(
    String threadId,
    String name,
  ) async {
    final current = threads[threadId] ?? archivedThreads[threadId]!;
    final renamed = codexThreadWithName(current, name);
    if (threads.containsKey(threadId)) {
      threads[threadId] = renamed;
    } else {
      archivedThreads[threadId] = renamed;
    }
    return const CodexThreadSetNameResponse();
  }

  @override
  Future<CodexThreadArchiveResponse> archiveThread(String threadId) async {
    archivedThreads[threadId] = threads.remove(threadId)!;
    return const CodexThreadArchiveResponse();
  }

  @override
  Future<CodexThreadUnarchiveResponse> unarchiveThread(String threadId) async {
    final restored = archivedThreads.remove(threadId)!;
    threads[threadId] = restored;
    return CodexThreadUnarchiveResponse(thread: restored);
  }

  @override
  Future<CodexThreadDeleteResponse> deleteThread(String threadId) async {
    threads.remove(threadId);
    archivedThreads.remove(threadId);
    return const CodexThreadDeleteResponse();
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
  Future<CodexThreadTurnsListResponse> listThreadTurns(
    CodexThreadTurnsListParams params,
  ) async => CodexThreadTurnsListResponse(
    data: threads[params.threadId]!.turns.reversed.toList(growable: false),
  );

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async => throw StateError('unused');

  @override
  Future<CodexThreadUnsubscribeResponse> unsubscribeThread(
    String threadId,
  ) async => const CodexThreadUnsubscribeResponse(
    status: CodexThreadUnsubscribeStatus.unsubscribed,
  );

  @override
  Future<CodexThreadStartResponse> startThread(
    CodexThreadStartParams params,
  ) async {
    startThreadParams.add(params);
    final projectless = params.cwd == null;
    final created = CodexThread(
      cliVersion: 'test',
      createdAt: 100,
      cwd: CodexV2AbsolutePathBuf(params.cwd ?? ''),
      ephemeral: false,
      id: projectless ? 'new-projectless-thread' : 'new-project-thread',
      modelProvider: 'openai',
      name: projectless ? 'New projectless thread' : 'New project thread',
      preview: '',
      sessionId: projectless ? 'new-projectless-thread' : 'new-project-thread',
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
  Future<CodexThreadResumeResponse> resumeThread(
    String threadId, {
    bool includeTurns = false,
    CodexThreadResumeInitialTurnsPageParams? initialTurnsPage,
  }) async {
    resumedThreadIds.add(threadId);
    final thread = threads[threadId]!;
    return CodexThreadResumeResponse(
      approvalPolicy: const CodexAskForApproval('never'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: thread.cwd,
      model: 'test',
      modelProvider: 'openai',
      initialTurnsPage: initialTurnsPage == null
          ? null
          : CodexTurnsPage(data: thread.turns.reversed.toList(growable: false)),
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
  String cwd = '/work/motif',
  CodexThreadStatus status = const CodexNotLoadedThreadStatus(),
}) => CodexThread(
  cliVersion: 'test',
  createdAt: updatedAt,
  cwd: CodexV2AbsolutePathBuf(cwd),
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
