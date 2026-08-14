import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/codex_feature_controller.dart';
import 'package:motif/motif/codex/codex_service_state.dart';
import 'package:motif/motif/codex/codex_state.dart';
import 'package:motif/motif/codex/codex_thread_catalog.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/resource_documents.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_controller.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_view_model.dart';
import 'package:motif/motif/ui/screens/codex_screen.dart';
import 'package:motif/motif/ui/screens/codex_resource_screens.dart';
import 'package:motif/motif/ui/screens/codex_thread_workspace.dart';
import 'package:motif/motif/ui/screens/session_screen.dart';
import 'package:motif/motif/ui/integration/app_codex_screen.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_server_transport.dart';
import 'support/workspace_connection_fixture.dart';

void main() {
  testWidgets('missing Codex CLI shows installation guidance', (tester) async {
    final app = await appState();
    final client = ScreenFakeClient()
      ..state = const CodexConnectionState(
        phase: CodexConnectionPhase.failed,
        failureKind: CodexConnectionFailureKind.cliNotFound,
        error: 'Install Codex or set MOTIFD_CODEX_PATH.',
      );
    final serviceState = readyServiceState(connection: client);

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: CodexState(),
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Codex CLI not found'), findsOneWidget);
    expect(find.textContaining('MOTIFD_CODEX_PATH'), findsOneWidget);
    expect(find.text('Codex connection failed'), findsNothing);
    expect(find.byKey(const ValueKey('codex-retry')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('desktop sidebar defaults open, toggles and resizes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final codex = CodexState(desktopSidebarVisible: false);
    final serviceState = readyServiceState();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: codex,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: codex,
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('codex-desktop-sidebar')), findsOneWidget);
    expect(codex.desktopSidebarVisible, isTrue);
    await tester.tap(find.byKey(const ValueKey('codex-sidebar-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('codex-desktop-sidebar')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('codex-sidebar-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.drag(
      find.byKey(const ValueKey('codex-sidebar-resize-handle')),
      const Offset(50, 0),
    );
    await tester.pump();
    expect(codex.sidebarWidth, greaterThan(340));

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  test('restores the last opened thread before its catalog is ready', () async {
    SharedPreferences.setMockInitialValues({});
    final sharedPreferences = await SharedPreferences.getInstance();
    final preferences = CodexState(preferences: sharedPreferences)
      ..setLastOpenedThreadId('server', 'thread');
    final client = ScreenFakeClient();
    final serviceState = readyServiceState(connection: client);
    final persistedThread = serviceState.catalog.allThreads.single;
    serviceState
      ..catalog = const CodexCatalogSnapshot.empty()
      ..catalogPhase = CodexCatalogPhase.loading;
    client.threadReadResponse = CodexThreadReadResponse(
      thread: persistedThread,
    );
    final controller = CodexFeatureController(
      serverId: 'server',
      preferences: preferences,
      connectionFactory: () => client,
      serviceFactory: () => serviceState,
      controlService: (_) async {},
    );

    await controller.start();
    await Future<void>.delayed(Duration.zero);

    expect(client.readThreadIds, ['thread']);
    expect(serviceState.selectedThread?.id, 'thread');
    expect(serviceState.catalogPhase, CodexCatalogPhase.loading);
    expect(preferences.lastOpenedThreadId('server'), 'thread');

    await controller.close();
    controller.dispose();
  });

  testWidgets('restores and records the server model preference', (
    tester,
  ) async {
    final app = await appState();
    final codex = CodexState()..setSelectedModelId('server', 'preferred-model');
    final serviceState = readyServiceState()
      ..models = const [
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
      ]
      ..selectedModelId = 'default-model';

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: codex,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: codex,
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(serviceState.selectedModelId, 'preferred-model');
    expect(serviceState.selectedReasoningEffort, 'high');
    serviceState.selectModel('default-model');
    expect(codex.selectedModelId('server'), 'default-model');

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('restores and records the server permission preference', (
    tester,
  ) async {
    final app = await appState();
    final codex = CodexState()
      ..setSelectedPermissionId('server', 'full-access');
    final serviceState = readyServiceState()
      ..permissionProfiles = const [
        CodexPermissionProfileSummary(
          allowed: true,
          description: 'Full access',
          id: 'full-access',
        ),
      ];

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: codex,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: codex,
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(serviceState.selectedPermissionId, 'full-access');
    serviceState.selectPermissionProfile(null);
    expect(codex.hasSelectedPermissionPreference('server'), isTrue);
    expect(codex.selectedPermissionId('server'), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('mobile welcome opens the sidebar by button or edge drag', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final codex = CodexState();
    final serviceState = readyServiceState();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: codex,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: codex,
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('codex-desktop-sidebar')), findsNothing);
    expect(find.byType(Drawer), findsNothing);
    expect(find.text('Start with a thread'), findsOneWidget);
    expect(
      find.text('You can also swipe in from the left edge.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('codex-open-sidebar-cta')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('codex-open-sidebar-cta')));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('codex-mode-timeline')));
    await tester.pump();
    expect(codex.sidebarMode, CodexSidebarMode.timeline);

    await tester.dragFrom(const Offset(590, 400), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);

    await tester.dragFrom(const Offset(1, 400), const Offset(420, 0));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('mobile new thread closes the sidebar and opens the thread', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final codex = CodexState();
    final client = ScreenFakeClient();
    final serviceState = readyServiceState(connection: client);

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: codex,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: codex,
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('codex-sidebar-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('codex-recents-new')));
    await tester.pumpAndSettle();

    expect(find.byType(Drawer), findsNothing);
    expect(serviceState.selectedThread?.id, 'new-thread');
    expect(find.byKey(const ValueKey('codex-thread-detail')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('mobile sidebar restores its scroll position after reopening', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final codex = CodexState();
    final serviceState = readyServiceState(
      threadCount: 30,
      projectlessThreads: true,
    );

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: codex,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: codex,
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('codex-sidebar-toggle')));
    await tester.pumpAndSettle();
    final projectList = find.byKey(const ValueKey('codex-project-list'));
    await tester.drag(projectList, const Offset(0, -360));
    await tester.pumpAndSettle();
    final beforeClose = tester.widget<ListView>(projectList).controller!.offset;
    expect(beforeClose, greaterThan(0));

    tester.state<ScaffoldState>(find.byType(Scaffold).first).closeDrawer();
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);

    await tester.tap(find.byKey(const ValueKey('codex-sidebar-toggle')));
    await tester.pumpAndSettle();
    final restored = tester
        .widget<ListView>(find.byKey(const ValueKey('codex-project-list')))
        .controller!
        .offset;
    expect(restored, closeTo(beforeClose, 0.5));

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('thread loading replaces the detail content on a white surface', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final serviceState = readyServiceState();
    serviceState
      ..selectedThread = serviceState.catalog.allThreads.single
      ..readingThreadId = 'next-thread';

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: CodexState(),
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('codex-thread-loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-detail')), findsNothing);
    final appBarTitle = find.byKey(const ValueKey('codex-thread-appbar-title'));
    expect(appBarTitle, findsOneWidget);
    expect(tester.widget<Text>(appBarTitle).data, 'Thread');
    expect(find.text('/work/motif'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.folder_outlined),
      ),
      findsNothing,
    );
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const ValueKey('codex-main-surface')))
          .color,
      MotifColors.light.surface,
    );

    serviceState
      ..readingThreadId = null
      ..notifyListeners();
    await tester.pump();
    expect(find.byKey(const ValueKey('codex-thread-loading')), findsNothing);
    final detail = tester.widget<Material>(
      find.byKey(const ValueKey('codex-thread-detail')),
    );
    expect(detail.color, MotifColors.light.surface);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('nested Codex route keeps Close beside the sidebar toggle', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final serviceState = readyServiceState();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          initialRoute: '/codex',
          theme: motifTheme(Brightness.light),
          routes: {
            '/': (_) => const Scaffold(body: Text('Sessions home')),
            '/codex': (_) => _CodexTestHost(
              app: app,
              codex: CodexState(),
              serviceState: serviceState,
            ),
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CloseButton), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    expect(find.byKey(const ValueKey('codex-sidebar-toggle')), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.text('Sessions home'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('Codex resources open directly without creating a workspace', (
    tester,
  ) async {
    final calls = <(String, Map<String, Object?>)>[];
    final app = await appStateWithServer((method, [params = const {}]) async {
      calls.add((method, Map<String, Object?>.from(params)));
      return const {};
    });
    final client = ScreenFakeClient(
      files: const {
        '/work/motif/lib/main.dart': 'final answer = 42;',
        '/work/motif/lib/other.dart': 'final other = 7;',
      },
    );
    final serviceState = readyServiceState(connection: client);
    serviceState.selectedThread = serviceState.catalog.allThreads.single;

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: CodexState(),
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pump();
    final workspace = tester.widget<CodexThreadWorkspace>(
      find.byType(CodexThreadWorkspace),
    );
    workspace.onOpenImage!(
      'data:image/png;base64,'
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodexNetworkImageScreen), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(client.readPaths, isEmpty);
    expect(
      calls.map((call) => call.$1),
      isNot(contains('codex.workspace.ensure')),
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    final document = DiffDocument.fromFilePatches(const [
      FilePatch(
        path: 'lib/main.dart',
        sourcePath: '/work/motif/lib/main.dart',
        patch: '--- a/lib/main.dart\n+++ b/lib/main.dart\n-old\n+new',
      ),
      FilePatch(
        path: 'lib/other.dart',
        sourcePath: '/work/motif/lib/other.dart',
        patch: '--- a/lib/other.dart\n+++ b/lib/other.dart\n-before\n+after',
      ),
    ]);
    workspace.onOpenTurnDiff!(document, initialPath: 'lib/main.dart');
    await tester.pumpAndSettle();

    expect(find.byType(CodexTurnDiffScreen), findsOneWidget);
    expect(find.text('Turn changes'), findsOneWidget);
    expect(find.text('+new'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('codex-turn-diff-sidebar')),
      findsOneWidget,
    );
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('codex-turn-diff-sidebar')))
          .dx,
      greaterThan(
        tester
            .getCenter(
              find.byKey(
                const ValueKey('codex-turn-diff-document-lib/main.dart'),
              ),
            )
            .dx,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('diff-list-file-lib/other.dart')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('codex-turn-diff-document-lib/other.dart')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('diff-list-file-lib/main.dart')),
    );
    await tester.pump();
    expect(
      calls.map((call) => call.$1),
      isNot(contains('codex.workspace.ensure')),
    );
    expect(find.byType(SessionScreen), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('diff-open-file-lib/main.dart')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodexFilePreviewScreen), findsOneWidget);
    expect(
      tester
          .widget<Scaffold>(
            find.byKey(const ValueKey('codex-file-preview-screen')),
          )
          .backgroundColor,
      MotifColors.light.surface,
    );
    expect(find.textContaining('final answer'), findsOneWidget);
    expect(client.readPaths, ['/work/motif/lib/main.dart']);
    expect(
      calls.map((call) => call.$1),
      isNot(contains('codex.workspace.ensure')),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('Codex file preview inherits the active dark theme', (
    tester,
  ) async {
    final state = readyServiceState(
      connection: ScreenFakeClient(
        files: const {'/work/motif/lib/main.dart': 'final answer = 42;'},
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        darkTheme: motifTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: CodexFilePreviewScreen(
          state: state,
          path: '/work/motif/lib/main.dart',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final screen = find.byKey(const ValueKey('codex-file-preview-screen'));
    expect(Theme.of(tester.element(screen)).brightness, Brightness.dark);
    expect(
      tester.widget<Scaffold>(screen).backgroundColor,
      MotifColors.dark.surface,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        darkTheme: motifTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: const CodexNetworkImageScreen(
          url:
              'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
        ),
      ),
    );
    await tester.pump();

    expect(
      tester
          .widget<Scaffold>(
            find.byKey(const ValueKey('codex-network-image-screen')),
          )
          .backgroundColor,
      MotifColors.dark.surface,
    );
  });

  testWidgets('workspace toolbar remains the explicit Session entry', (
    tester,
  ) async {
    final calls = <(String, Map<String, Object?>)>[];
    final app = await appStateWithServer((method, [params = const {}]) async {
      calls.add((method, Map<String, Object?>.from(params)));
      if (method == 'codex.workspace.ensure') {
        return const {
          'session': {
            'name': '__motif_internal_thread',
            'workdir': '/work/motif',
          },
        };
      }
      return const {};
    });
    final serviceState = readyServiceState();
    serviceState.selectedThread = serviceState.catalog.allThreads.single;

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: CodexState(),
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-open-thread-workspace')));
    await tester.pumpAndSettle();

    final ensureCall = calls.singleWhere(
      (call) => call.$1 == 'codex.workspace.ensure',
    );
    expect(ensureCall.$2, {'thread_id': 'thread', 'cwd': '/work/motif'});
    final screen = tester.widget<SessionScreen>(find.byType(SessionScreen));
    expect(screen.session, '__motif_internal_thread');
    expect(screen.allowSessionSwitching, isFalse);
    expect(screen.titleOverride, 'Thread');
    expect(screen.initialTarget, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('side chat opens directly from Codex without creating a PTY', (
    tester,
  ) async {
    final serverCalls = <String>[];
    final app = await appStateWithServer((method, [params = const {}]) async {
      serverCalls.add(method);
      return const {};
    });
    final serviceState = readyServiceState();
    serviceState.selectedThread = serviceState.catalog.allThreads.single;
    final sideChatClient = ScreenFakeClient();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: CodexState(),
            serviceState: serviceState,
            connection: sideChatClient,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('open-side-chat')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('side-chat-sidebar')), findsOneWidget);
    expect(
      tester
          .widget<CodexThreadWorkspace>(find.byType(CodexThreadWorkspace))
          .onOpenTurnDiff,
      isNotNull,
    );
    expect(sideChatClient.forkParams, hasLength(1));
    expect(sideChatClient.forkParams.single.threadId, 'thread');
    expect(sideChatClient.forkParams.single.ephemeral, isTrue);
    expect(sideChatClient.forkParams.single.excludeTurns, isTrue);
    expect(serverCalls, isNot(contains('codex.workspace.ensure')));
    expect(find.byType(SessionScreen), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('restart discards associated local workspaces and reconnects', (
    tester,
  ) async {
    final calls = <String>[];
    final app = await appStateWithServer((method, [params = const {}]) async {
      calls.add(method);
      if (method == 'codex.restart') {
        return const {
          'running': true,
          'closed_sessions': ['__motif_internal_old'],
        };
      }
      return const {};
    });
    app.workspaceForSession('server', '__motif_internal_old');
    final serviceState = readyServiceState();
    final client = serviceState.connection as ScreenFakeClient;

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: _CodexTestHost(
            app: app,
            codex: CodexState(),
            serviceState: serviceState,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-service-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart Codex'));
    await tester.pumpAndSettle();

    expect(calls, contains('codex.restart'));
    expect(app.existingWorkspace('server', '__motif_internal_old'), isNull);
    expect(client.retryCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('stop discards associated workspaces and leaves Codex', (
    tester,
  ) async {
    final calls = <String>[];
    final app = await appStateWithServer((method, [params = const {}]) async {
      calls.add(method);
      if (method == 'codex.stop') {
        return const {
          'running': false,
          'closed_sessions': ['__motif_internal_old'],
        };
      }
      return const {};
    });
    app.workspaceForSession('server', '__motif_internal_old');
    final serviceState = readyServiceState();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          initialRoute: '/codex',
          theme: motifTheme(Brightness.light),
          routes: {
            '/': (_) => const Scaffold(body: Text('Sessions home')),
            '/codex': (_) => _CodexTestHost(
              app: app,
              codex: CodexState(),
              serviceState: serviceState,
            ),
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-service-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop Codex'));
    await tester.pumpAndSettle();

    expect(calls, contains('codex.stop'));
    expect(app.existingWorkspace('server', '__motif_internal_old'), isNull);
    expect(find.text('Sessions home'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });
}

final class _CodexTestHost extends StatefulWidget {
  const _CodexTestHost({
    required this.app,
    required this.codex,
    required this.serviceState,
    this.connection,
  });

  final AppState app;
  final CodexState codex;
  final CodexServiceState serviceState;
  final CodexAppServerClient? connection;

  @override
  State<_CodexTestHost> createState() => _CodexTestHostState();
}

final class _CodexTestHostState extends State<_CodexTestHost> {
  late final CodexFeatureController _controller = CodexFeatureController(
    serverId: 'server',
    preferences: widget.codex,
    connectionFactory: () =>
        widget.connection ?? widget.serviceState.connection,
    serviceFactory: () => widget.serviceState,
    controlService: (action) async {
      final method = switch (action) {
        CodexServiceAction.restart => 'codex.restart',
        CodexServiceAction.stop => 'codex.stop',
      };
      final body = await widget.app
          .serverInstance('server')
          .transport
          .call(method);
      final closed = (body['closed_sessions'] as List? ?? const [])
          .whereType<String>();
      await widget.app.discardWorkspaces('server', closed);
    },
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CodexScreen(
    controller: _controller,
    onWorkspaceRequested: (request) => CodexSessionCoordinator.open(
      context,
      app: widget.app,
      serverId: 'server',
      request: request,
    ),
  );
}

Future<AppState> appState() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices.defaults(),
  );
}

Future<AppState> appStateWithServer(TestServerCall call) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final app = AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices.defaults(),
    serverTransportFactory: (_) =>
        TestServerTransport(live: true, onCall: call),
    workspaceConnectionFactory: (_, session) =>
        _ReadyWorkspaceConnection(session),
  );
  await app.servers.add(
    const MotifServer(id: 'server', name: 'Server', host: '127.0.0.1'),
  );
  app.serverInstance('server');
  return app;
}

CodexServiceState readyServiceState({
  ScreenFakeClient? connection,
  int threadCount = 1,
  bool projectlessThreads = false,
}) {
  final threads = [
    for (var index = 0; index < threadCount; index++)
      CodexThread(
        cliVersion: 'test',
        createdAt: 1,
        cwd: CodexV2AbsolutePathBuf(projectlessThreads ? '' : '/work/motif'),
        ephemeral: false,
        id: index == 0 ? 'thread' : 'thread-$index',
        modelProvider: 'openai',
        name: index == 0 ? 'Thread' : 'Thread $index',
        preview: '',
        sessionId: index == 0 ? 'thread' : 'thread-$index',
        source: const CodexSessionSource('cli'),
        status: const CodexNotLoadedThreadStatus(),
        turns: const [],
        updatedAt: index + 1,
      ),
  ];
  return CodexServiceState(
      serverId: 'server',
      connection: connection ?? ScreenFakeClient(),
    )
    ..catalog = buildCodexCatalog(threads, null)
    ..catalogPhase = CodexCatalogPhase.ready;
}

final class ScreenFakeClient extends ChangeNotifier
    implements CodexAppServerClient {
  ScreenFakeClient({this.files = const {}});

  final Map<String, String> files;
  final List<String> readPaths = [];
  final StreamController<Map<String, Object?>> _raw =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<CodexJsonEncodable> _typed =
      StreamController<CodexJsonEncodable>.broadcast();
  final List<CodexThreadForkParams> forkParams = [];
  final List<String> readThreadIds = [];
  CodexThreadReadResponse? threadReadResponse;

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
  Future<void> retry() async => retryCount++;

  int retryCount = 0;

  @override
  Future<CodexThreadListResponse> listThreads(
    CodexThreadListParams params,
  ) async => const CodexThreadListResponse(data: []);

  @override
  Future<CodexThreadSetNameResponse> setThreadName(
    String threadId,
    String name,
  ) async => const CodexThreadSetNameResponse();

  @override
  Future<CodexThreadArchiveResponse> archiveThread(String threadId) async =>
      const CodexThreadArchiveResponse();

  @override
  Future<CodexThreadUnarchiveResponse> unarchiveThread(String threadId) async =>
      throw StateError('unused');

  @override
  Future<CodexThreadDeleteResponse> deleteThread(String threadId) async =>
      const CodexThreadDeleteResponse();

  @override
  Future<CodexThreadReadResponse> readThread(
    String threadId, {
    bool includeTurns = false,
  }) async {
    readThreadIds.add(threadId);
    return threadReadResponse ?? (throw StateError('unused'));
  }

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async {
    forkParams.add(params);
    final thread = CodexThread(
      cliVersion: 'test',
      createdAt: 1,
      cwd: const CodexV2AbsolutePathBuf('/work/motif'),
      ephemeral: true,
      forkedFromId: params.threadId,
      id: 'side-chat',
      modelProvider: 'openai',
      parentThreadId: params.threadId,
      preview: '',
      sessionId: 'side-chat',
      source: const CodexSessionSource('cli'),
      status: const CodexIdleThreadStatus(),
      turns: const [],
      updatedAt: 1,
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
  ) async => const CodexThreadUnsubscribeResponse(
    status: CodexThreadUnsubscribeStatus.unsubscribed,
  );

  @override
  Future<CodexThreadStartResponse> startThread(
    CodexThreadStartParams params,
  ) async {
    final thread = CodexThread(
      cliVersion: 'test',
      createdAt: 2,
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
      updatedAt: 2,
    );
    return CodexThreadStartResponse(
      approvalPolicy: const CodexAskForApproval('never'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: thread.cwd,
      model: params.model ?? 'test',
      modelProvider: 'openai',
      sandbox: const CodexDangerFullAccessSandboxPolicy(),
      thread: thread,
    );
  }

  @override
  Future<CodexThreadResumeResponse> resumeThread(
    String threadId, {
    bool includeTurns = false,
  }) async => throw StateError('unused');

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
  Future<CodexFsReadFileResponse> readFile(String path) async {
    readPaths.add(path);
    final content = files[path];
    if (content == null) throw StateError('Missing test file: $path');
    return CodexFsReadFileResponse(
      dataBase64: base64Encode(utf8.encode(content)),
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

final class _ReadyWorkspaceConnection extends WorkspaceConnectionController {
  _ReadyWorkspaceConnection(String session) : super(session: session) {
    updateConnectionState(ConnAttached(session), live: true);
    ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)];
    views = const [ViewInfo(id: 'view-1', spec: PtyViewSpec('pty-1'))];
    activeViewId = 'view-1';
  }

  @override
  Future<void> attach() async {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> disconnect() async {}
}
