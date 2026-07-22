import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_controller.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_view_model.dart';
import 'package:motif/motif/state/workspace/workspace_content_view_model.dart';
import 'package:motif/motif/state/workspace/workspace_retention_policy.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/state/workspace/terminal/terminal_controller.dart';
import 'package:motif/motif/state/workspace/terminal/terminal_view_model.dart';
import 'package:motif/motif/state/workspace/terminal/terminal_runtime_policy.dart';
import 'package:motif/motif/state/workspace/view/view_controller.dart';
import 'package:motif/motif/state/workspace/view/view_tabs_view_model.dart';
import 'package:motif/motif/state/workspace/workspace_api.dart';
import 'package:motif/motif/terminal/terminal_input.dart';
import 'package:motif/motif/terminal/terminal_key.dart';
import 'package:motif/motif/terminal/terminal_link.dart';
import 'package:motif/motif/terminal/motif_terminal_view.dart';
import 'package:motif/motif/terminal/terminal_session.dart';
import 'package:motif/motif/ui/screens/file_tree_panel.dart';
import 'package:motif/motif/ui/screens/git_diff_panel.dart';
import 'package:motif/motif/ui/screens/session_screen.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_server_transport.dart';
import 'support/workspace_connection_fixture.dart';

class _RouteCounter extends NavigatorObserver {
  int pushes = 0;
  int replacements = 0;
  Route<dynamic>? lastReplacement;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    replacements++;
    lastReplacement = newRoute;
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

class _RecordingWorkspaceConnectionController
    extends _ShortcutWorkspaceConnectionController {}

class _SessionMenuWorkspaceConnectionController
    extends WorkspaceConnectionController {
  final List<String> attached = [];
  List<SessionInfo> sessions = [];
  int detaches = 0;
  int disconnects = 0;
  _SessionMenuWorkspaceConnectionController({
    String session = 'test-session',
    bool initiallyAttached = true,
  }) : super(session: session) {
    updateConnectionState(
      initiallyAttached ? ConnAttached(session) : const ConnConnected(),
      live: true,
    );
    // Seed a terminal so SessionScreen's attach-if-needed path does not call
    // createPty (which needs a live RpcClient and would toast + leave a timer).
    ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)];
    views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))];
    activeViewId = 'v1';
  }

  @override
  Future<void> detach() async {
    detaches++;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<void> attach() async {
    attached.add(session);
    updateConnectionState(ConnAttached(session), live: true);
  }
}

class _GitDiffRouteWorkspaceConnectionController
    extends _SessionMenuWorkspaceConnectionController {
  static const _files = [
    DiffSummaryFile(
      path: 'lib/motif/ui/screens/session_screen.dart',
      additions: 3,
      deletions: 1,
    ),
  ];

  late final WorkspaceApi _fakeWorkspace = WorkspaceApi(
    content: WorkspaceContentViewModel(),
    transport: WorkspaceApiTransport(
      isAvailable: () => true,
      call: (method, [params = const {}]) async {
        final path = params['path'] as String?;
        if (method == 'git.diffSummary') {
          final files = path == null
              ? _files
              : _files.where((file) => file.path == path);
          return {
            'files': [
              for (final file in files)
                {
                  'path': file.path,
                  'additions': file.additions,
                  'deletions': file.deletions,
                },
            ],
          };
        }
        if (method == 'git.diff') {
          final diffPath = path ?? _files.first.path;
          return {
            'patch': [
              'diff --git a/$diffPath b/$diffPath',
              'index abc123..def456 100644',
              '--- a/$diffPath',
              '+++ b/$diffPath',
              '@@ -1,1 +1,1 @@',
              '+narrow route diff',
            ].join('\n'),
          };
        }
        return const {};
      },
      writeFileBytes: (_, _) async => '',
    ),
    activeCwd: () => '/work',
  );

  @override
  WorkspaceApi get workspace => _fakeWorkspace;
}

class _DirectoryLinkWorkspaceConnectionController
    extends _SessionMenuWorkspaceConnectionController {
  final List<String> statPaths = [];
  final List<String> treePaths = [];

  late final WorkspaceApi _fakeWorkspace = WorkspaceApi(
    content: WorkspaceContentViewModel(),
    transport: WorkspaceApiTransport(
      isAvailable: () => true,
      call: (method, [params = const {}]) async {
        final path = params['path']! as String;
        if (method == 'fs.stat') {
          statPaths.add(path);
          return const {'type': 'dir', 'size': 0, 'mtime': 0};
        }
        if (method == 'fs.tree') {
          treePaths.add(path);
          return const {'entries': <Object?>[]};
        }
        return const {};
      },
      writeFileBytes: (_, _) async => '',
    ),
    activeCwd: () => '/work',
  );

  @override
  WorkspaceApi get workspace => _fakeWorkspace;
}

class _BlockingDetachWorkspaceConnectionController
    extends _SessionMenuWorkspaceConnectionController {
  final Completer<void> detachCompleter = Completer<void>();

  @override
  Future<void> detach() async {
    detaches++;
    await detachCompleter.future;
  }
}

/// Connected to a server but not attached to any session — `session.detach`
/// would be rejected server-side, so close-all must skip it.
class _ConnectedNotAttachedWorkspaceConnectionController
    extends _SessionMenuWorkspaceConnectionController {
  _ConnectedNotAttachedWorkspaceConnectionController() {
    updateConnectionState(const ConnConnected(), live: true);
  }
}

class _ShortcutWorkspaceConnectionController
    extends WorkspaceConnectionController {
  _ShortcutWorkspaceConnectionController({String session = 'test-session'})
    : super(session: session) {
    updateConnectionState(ConnAttached(session), live: true);
  }

  int createdPtys = 0;
  final List<String> closedViews = [];
  final List<String> writtenPtyIds = [];
  final List<List<int>> writtenPtyData = [];
  final List<TerminalInputEvent> terminalInputs = [];

  void recordTerminalInput([String ptyId = 'pty-1']) {
    terminal.registerTerminalInputSink(ptyId, (event) {
      terminalInputs.add(event);
      return true;
    });
  }

  void simulateConnectionState(
    WorkspaceConnectionStatus state, {
    required bool live,
  }) => updateConnectionState(state, live: live);

  late final TerminalViewModel _terminalViewModel = TerminalViewModel(
    ptys: ObservableList(),
    runningCommand: ObservableMap(),
    shellKind: ObservableMap(),
    shellContext: ObservableMap(),
  );
  late final ViewTabsViewModel _viewTabs = ViewTabsViewModel(
    items: ObservableList(),
  );
  late final TerminalController _fakeTerminal = TerminalController(
    viewModel: _terminalViewModel,
    transport: TerminalTransport(
      canInput: () => true,
      call: (method, [params = const {}]) async {
        if (method == 'pty.create') {
          createdPtys++;
          final pty = PtyInfo(
            id: 'new-pty-$createdPtys',
            cmd: params['cmd'] as String?,
            cwd: params['cwd'] as String?,
            cols: params['cols']! as int,
            rows: params['rows']! as int,
          );
          final view = ViewInfo(
            id: 'new-view-$createdPtys',
            spec: PtyViewSpec(pty.id),
          );
          _viewTabs.items.add(view);
          _viewTabs.activeViewId = view.id;
          return {
            'info': {
              'id': pty.id,
              'cmd': pty.cmd,
              'cwd': pty.cwd,
              'cols': pty.cols,
              'rows': pty.rows,
            },
          };
        }
        return const {};
      },
      writePty: (ptyId, data) async {
        writtenPtyIds.add(ptyId);
        writtenPtyData.add(List<int>.from(data));
      },
      resizePty: (_, _, _) async {},
      ensurePtyStream: (_) async {},
      closePtyStream: (_) async {},
      syncPtyStreams: (_) async {},
      waitForPtyReplay: (_) async {},
      resyncPtyStream: (_, {required reason}) async {},
    ),
    runtime: const MobileTerminalRuntimePolicy(),
    viewProjection: TerminalViewProjection(
      activePtyId: () {
        final spec = _viewTabs.active?.spec;
        return spec is PtyViewSpec ? spec.ptyId : null;
      },
      liveTabPtyIds: () => {
        for (final view in _viewTabs.items)
          if (view.spec case PtyViewSpec(:final ptyId)) ptyId,
      },
    ),
  );
  late final ViewController _fakeViews = ViewController(
    viewModel: _viewTabs,
    transport: ViewTransport(
      isAvailable: () => true,
      call: (method, [params = const {}]) async {
        if (method == 'view.activate') {
          _fakeViews.handleActiveChanged(params['view_id'] as String?);
        } else if (method == 'view.close') {
          closedViews.add(params['view_id']! as String);
        }
        return const {};
      },
    ),
    callbacks: ViewProjectionCallbacks(
      onTabsChanged: () {},
      onActiveChanged: () {},
    ),
  );

  @override
  TerminalController get terminal => _fakeTerminal;

  @override
  ViewController get viewsController => _fakeViews;
}

class _SuspendedWorkspaceConnectionController
    extends _ShortcutWorkspaceConnectionController {
  void emitSuspended() {
    updateConnectionState(
      const ConnSuspended('Tailscale disconnected', session: 'test-session'),
      live: false,
    );
  }
}

Future<AppState> _appStateWith(
  Map<String, WorkspaceConnectionController> clients, {
  WorkspaceRetentionPolicy? workspaceRetentionPolicy,
  WorkspaceConnectionController Function(MotifServer server, String session)?
  workspaceConnectionFactory,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final serverSessions = {
    for (final entry in clients.entries)
      entry.key: [
        if (entry.value case _SessionMenuWorkspaceConnectionController fixture)
          ...fixture.sessions,
      ],
  };
  final app = AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices.defaults(),
    serverTransportFactory: (server) {
      final sessions = serverSessions[server.id] ?? const <SessionInfo>[];
      return TestServerTransport(
        live: true,
        onCall: (method, [params = const {}]) async {
          if (method != 'session.list') return const {};
          return {
            'sessions': [
              for (final session in sessions)
                {
                  'name': session.name,
                  'workdir': session.workdir,
                  'created_at': session.createdAt,
                  'client_count': session.clientCount,
                },
            ],
          };
        },
      );
    },
    workspaceConnectionFactory:
        workspaceConnectionFactory ??
        (server, session) {
          final configured = clients[server.id];
          if (configured != null && configured.session == session) {
            return configured;
          }
          return _SessionMenuWorkspaceConnectionController(session: session);
        },
    workspaceRetentionPolicy: workspaceRetentionPolicy,
  );
  for (final entry in clients.entries) {
    await app.servers.add(
      MotifServer(
        id: entry.key,
        name: entry.key == 'server-1' ? 'Dev' : 'Prod',
        host: '127.0.0.1',
      ),
    );
    app.serverInstance(entry.key);
  }
  return app;
}

Future<AppState> _appState({
  WorkspaceConnectionController? motif,
  WorkspaceConnectionController Function(MotifServer server, String session)?
  workspaceConnectionFactory,
}) {
  return _appStateWith({
    'server-1': motif ?? _SessionMenuWorkspaceConnectionController(),
  }, workspaceConnectionFactory: workspaceConnectionFactory);
}

Future<_RouteCounter> _pumpSession(
  WidgetTester tester,
  Size size, {
  WorkspaceConnectionController? motif,
  WorkspaceConnectionController Function(MotifServer server, String session)?
  workspaceConnectionFactory,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final app = await _appState(
    motif: motif,
    workspaceConnectionFactory: workspaceConnectionFactory,
  );
  final routes = _RouteCounter();
  await tester.pumpWidget(
    MotifScope(
      appState: app,
      child: MaterialApp(
        theme: motifTheme(Brightness.dark),
        navigatorObservers: [routes],
        home: const SessionScreen(
          serverId: 'server-1',
          session: 'test-session',
        ),
      ),
    ),
  );
  await tester.pump();
  return routes;
}

Future<void> _sendPrimaryShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  final primary =
      defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.iOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(primary);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(primary);
  await tester.pump();
}

Future<void> _sendControlShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  testWidgets('large screen puts terminal tabs in the title bar', (
    tester,
  ) async {
    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';

    await _pumpSession(tester, const Size(1024, 768), motif: motif);

    expect(find.byKey(const ValueKey('title-tab-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('body-tab-bar')), findsNothing);
    expect(find.byKey(const ValueKey('bottom-bar-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('bottom-bar')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('title-tab-bar'))).height,
      44,
    );

    await tester.tap(find.byKey(const ValueKey('bottom-bar-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('bottom-bar')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bottom-bar-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('bottom-bar')), findsNothing);

    expect(
      find.byWidgetPredicate(
        (widget) => widget is Title && widget.title == 'test-session',
      ),
      findsOneWidget,
    );
  });

  testWidgets('terminal page creates a PTY after async attachment completes', (
    tester,
  ) async {
    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';

    await _pumpSession(tester, const Size(1024, 768), motif: motif);
    expect(motif.createdPtys, 0);

    motif
      ..ptys = const []
      ..views = const []
      ..activeViewId = null;
    motif.simulateConnectionState(const ConnFailed('offline'), live: false);
    await tester.pump();

    motif.simulateConnectionState(
      const ConnAttached('test-session'),
      live: true,
    );
    await tester.pump();

    expect(motif.createdPtys, 1);
    expect(motif.terminal.viewModel.ptys, hasLength(1));
  });

  testWidgets('Android push transition mounts terminal pane immediately', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final motif = _ShortcutWorkspaceConnectionController()
        ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
        ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
        ..activeViewId = 'v1';
      final app = await _appState(motif: motif);

      await tester.pumpWidget(
        MotifScope(
          appState: app,
          child: MaterialApp(
            theme: motifTheme(Brightness.dark),
            home: const Scaffold(body: Text('Session list')),
          ),
        ),
      );
      await tester.pump();

      Navigator.of(tester.element(find.text('Session list'))).push(
        MaterialPageRoute<void>(
          builder: (_) => const SessionScreen(
            serverId: 'server-1',
            session: 'test-session',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byType(SessionScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('terminal-pty-1')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS push transition mounts terminal pane immediately', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final motif = _ShortcutWorkspaceConnectionController()
        ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
        ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
        ..activeViewId = 'v1';
      final app = await _appState(motif: motif);

      await tester.pumpWidget(
        MotifScope(
          appState: app,
          child: MaterialApp(
            theme: motifTheme(Brightness.dark),
            home: const Scaffold(body: Text('Session list')),
          ),
        ),
      );
      await tester.pump();

      Navigator.of(tester.element(find.text('Session list'))).push(
        MaterialPageRoute<void>(
          builder: (_) => const SessionScreen(
            serverId: 'server-1',
            session: 'test-session',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byType(SessionScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('terminal-pty-1')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('suspended connection keeps terminal pane and shows overlay', (
    tester,
  ) async {
    final motif = _SuspendedWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';

    await _pumpSession(tester, const Size(1024, 768), motif: motif);
    motif.emitSuspended();
    await tester.pump();

    expect(find.byKey(const ValueKey('terminal-pty-1')), findsOneWidget);
    expect(find.text('Tailscale disconnected'), findsOneWidget);
  });

  testWidgets('narrow screen keeps terminal tabs in the body', (tester) async {
    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';

    await _pumpSession(tester, const Size(700, 768), motif: motif);

    expect(find.byKey(const ValueKey('title-tab-bar')), findsNothing);
    expect(find.byKey(const ValueKey('body-tab-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('bottom-bar-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('bottom-bar')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('body-tab-bar'))).height,
      44,
    );
    expect(find.text('test-session'), findsOneWidget);
  });

  testWidgets('mobile horizontal swipe scrolls tabs without a long press', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final motif = _ShortcutWorkspaceConnectionController()
        ..ptys = const [PtyInfo(id: 'seed', cols: 80, rows: 24)]
        ..views = const [
          ViewInfo(id: 'v1', spec: OtherViewSpec('first-wide-tab')),
          ViewInfo(id: 'v2', spec: OtherViewSpec('second-wide-tab')),
          ViewInfo(id: 'v3', spec: OtherViewSpec('third-wide-tab')),
          ViewInfo(id: 'v4', spec: OtherViewSpec('fourth-wide-tab')),
          ViewInfo(id: 'v5', spec: OtherViewSpec('fifth-wide-tab')),
        ]
        ..activeViewId = 'v1';

      await _pumpSession(tester, const Size(360, 768), motif: motif);

      final tabList = find.byType(ReorderableListView);
      final scrollable = find.descendant(
        of: tabList,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels, 0);
      expect(find.byType(ReorderableDelayedDragStartListener), findsWidgets);
      expect(find.byType(ReorderableDragStartListener), findsNothing);

      await tester.drag(
        find.byKey(const ValueKey('tab-v1')),
        const Offset(-220, 0),
      );
      await tester.pump();

      expect(position.pixels, greaterThan(0));
      expect(find.byKey(const ValueKey('tab-drag-feedback')), findsNothing);
      expect(motif.views.map((view) => view.id), [
        'v1',
        'v2',
        'v3',
        'v4',
        'v5',
      ]);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('switching tabs centers the active tab when bounds allow', (
    tester,
  ) async {
    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'seed', cols: 80, rows: 24)]
      ..views = const [
        ViewInfo(id: 'v1', spec: OtherViewSpec('first-wide-tab')),
        ViewInfo(id: 'v2', spec: OtherViewSpec('second-wide-tab')),
        ViewInfo(id: 'v3', spec: OtherViewSpec('third-wide-tab')),
        ViewInfo(id: 'v4', spec: OtherViewSpec('fourth-wide-tab')),
        ViewInfo(id: 'v5', spec: OtherViewSpec('fifth-wide-tab')),
      ]
      ..activeViewId = 'v1';

    await _pumpSession(tester, const Size(360, 768), motif: motif);

    final tabList = find.byType(ReorderableListView);
    final scrollable = find.descendant(
      of: tabList,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);

    final viewport = tester.getRect(scrollable);
    final secondTabBeforeScroll = tester.getRect(
      find.byKey(const ValueKey('tab-v2')),
    );
    final secondTabOverflow = secondTabBeforeScroll.right - viewport.right;
    position.jumpTo(position.pixels + secondTabOverflow - 2);
    await tester.pump();
    expect(
      tester.getRect(find.byKey(const ValueKey('tab-v2'))).right,
      greaterThan(viewport.right),
    );

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.digit2);
    await tester.pumpAndSettle();

    expect(motif.activeViewId, 'v2');
    final secondTab = tester.getRect(find.byKey(const ValueKey('tab-v2')));
    expect((secondTab.center.dx - viewport.center.dx).abs(), lessThan(2.5));

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.digit9);
    await tester.pumpAndSettle();

    expect(motif.activeViewId, 'v5');
    expect(position.pixels, greaterThan(0));
    final activeTab = tester.getRect(find.byKey(const ValueKey('tab-v5')));
    expect(activeTab.left, greaterThanOrEqualTo(viewport.left - 0.5));
    expect(activeTab.right, lessThanOrEqualTo(viewport.right + 0.5));

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();

    expect(motif.activeViewId, 'v1');
    final firstTab = tester.getRect(find.byKey(const ValueKey('tab-v1')));
    expect(firstTab.left, greaterThanOrEqualTo(viewport.left - 0.5));
    expect(firstTab.right, lessThanOrEqualTo(viewport.right + 0.5));
  });

  testWidgets('mobile long press starts tab reorder', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final motif = _ShortcutWorkspaceConnectionController()
        ..ptys = const [PtyInfo(id: 'seed', cols: 80, rows: 24)]
        ..views = const [
          ViewInfo(id: 'v1', spec: OtherViewSpec('first-tab')),
          ViewInfo(id: 'v2', spec: OtherViewSpec('second-tab')),
        ]
        ..activeViewId = 'v1';

      await _pumpSession(tester, const Size(700, 768), motif: motif);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('first-tab')),
      );
      await tester.pump(kLongPressTimeout - const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('tab-drag-feedback')), findsNothing);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 120));

      final feedback = find.byKey(const ValueKey('tab-drag-feedback'));
      expect(feedback, findsOneWidget);
      expect(tester.widget<Material>(feedback).elevation, greaterThan(0));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(feedback, findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop pointer drag starts tab reorder immediately', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final motif = _ShortcutWorkspaceConnectionController()
        ..ptys = const [PtyInfo(id: 'seed', cols: 80, rows: 24)]
        ..views = const [
          ViewInfo(id: 'v1', spec: OtherViewSpec('first-tab')),
          ViewInfo(id: 'v2', spec: OtherViewSpec('second-tab')),
        ]
        ..activeViewId = 'v1';

      await _pumpSession(tester, const Size(1024, 768), motif: motif);
      expect(find.byType(ReorderableDragStartListener), findsWidgets);
      expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('first-tab')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      final feedback = find.byKey(const ValueKey('tab-drag-feedback'));
      expect(feedback, findsOneWidget);
      expect(tester.widget<Material>(feedback).elevation, greaterThan(0));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(feedback, findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('bottom input state is scoped to the active tab', (tester) async {
    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [
        PtyInfo(id: 'pty-1', cols: 80, rows: 24),
        PtyInfo(id: 'pty-2', cols: 80, rows: 24),
      ]
      ..views = const [
        ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1')),
        ViewInfo(id: 'v2', spec: PtyViewSpec('pty-2')),
      ]
      ..activeViewId = 'v1';

    await _pumpSession(tester, const Size(700, 768), motif: motif);

    TextField inputField() => tester.widget<TextField>(find.byType(TextField));

    await tester.enterText(find.byType(TextField), 'first tab');
    await tester.pump();
    final firstGroup = inputField().groupId;
    // The compose box must NOT force the ASCII keyboard (visiblePassword) the
    // terminal once used — that hides the iOS language switch and blocks CJK
    // IMEs. It keeps the full multiline keyboard; the English locale hint only
    // biases a fresh keyboard toward English without locking out switching.
    expect(inputField().keyboardType, TextInputType.multiline);
    expect(inputField().textInputAction, TextInputAction.send);
    expect(inputField().hintLocales, terminalEnglishHintLocales);
    // Must remain true: Flutter otherwise marks Android fields as visible
    // passwords, which blocks language switching in some IMEs.
    expect(inputField().enableSuggestions, isTrue);

    await tester.tap(find.byKey(const ValueKey('tab-v2')));
    await tester.pump();
    expect(motif.activeViewId, 'v2');
    expect(inputField().controller?.text, isEmpty);
    expect(inputField().groupId, isNot(same(firstGroup)));

    await tester.enterText(find.byType(TextField), 'second tab');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('tab-v1')));
    await tester.pump();
    expect(inputField().controller?.text, 'first tab');

    await tester.tap(find.byKey(const ValueKey('tab-v2')));
    await tester.pump();
    expect(inputField().controller?.text, 'second tab');

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyT);
    expect(motif.activeViewId, 'new-view-1');
    expect(inputField().controller?.text, isEmpty);
  });

  testWidgets('send button routes paste then semantic Enter', (tester) async {
    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';

    await _pumpSession(tester, const Size(700, 768), motif: motif);
    motif.recordTerminalInput();

    await tester.enterText(find.byType(TextField), 'echo hi');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    expect(motif.writtenPtyIds, isEmpty);
    expect(motif.terminalInputs, hasLength(3));
    expect(
      (motif.terminalInputs[0] as TerminalPasteInput).bytes,
      'echo hi'.codeUnits,
    );
    expect(
      motif.terminalInputs[1],
      isA<TerminalKeyInput>()
          .having((input) => input.keyId, 'keyId', TerminalKeyIds.enter)
          .having((input) => input.action, 'action', TerminalKeyAction.press),
    );
    expect(
      motif.terminalInputs[2],
      isA<TerminalKeyInput>().having(
        (input) => input.action,
        'action',
        TerminalKeyAction.release,
      ),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
  });

  testWidgets('bottom quick commands update when command store changes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';
    final app = await _appState(motif: motif);
    await app.commands.setGlobal([
      QuickCommand.bytes('first', 'First', [1]),
    ]);

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const SessionScreen(
            serverId: 'server-1',
            session: 'test-session',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('First'), findsOneWidget);
    expect(find.byTooltip('Second'), findsNothing);

    await app.commands.setGlobal([
      QuickCommand.bytes('second', 'Second', [2]),
    ]);
    await tester.pump();

    expect(find.byTooltip('First'), findsNothing);
    expect(find.byTooltip('Second'), findsOneWidget);
  });

  testWidgets('quick commands route text semantically and preserve raw keys', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';
    final app = await _appState(motif: motif);
    await app.commands.setGlobal([
      QuickCommand.text('run', 'Run', 'ls\n'),
      QuickCommand.bytes('escape', 'Escape', [0x1b]),
    ]);

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const SessionScreen(
            serverId: 'server-1',
            session: 'test-session',
          ),
        ),
      ),
    );
    await tester.pump();
    motif.recordTerminalInput();

    await tester.tap(find.byTooltip('Run'));
    await tester.pump();

    expect(motif.writtenPtyIds, isEmpty);
    expect(motif.terminalInputs, hasLength(3));
    expect(
      (motif.terminalInputs.first as TerminalPasteInput).bytes,
      'ls'.codeUnits,
    );
    expect(
      motif.terminalInputs.skip(1),
      everyElement(
        isA<TerminalKeyInput>().having(
          (input) => input.keyId,
          'keyId',
          TerminalKeyIds.enter,
        ),
      ),
    );

    await tester.tap(find.byTooltip('Escape'));
    await tester.pump();

    expect(motif.writtenPtyIds.last, 'pty-1');
    expect(motif.writtenPtyData.last, [0x1b]);
  });

  testWidgets('multiline bottom input lifts terminal without resizing it', (
    tester,
  ) async {
    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';

    await _pumpSession(tester, const Size(700, 768), motif: motif);

    final terminal = find.byKey(const ValueKey('terminal-pty-1'));
    final inputBar = find.byKey(const ValueKey('bottom-bar'));
    final initialTerminalSize = tester.getSize(terminal);
    final initialTerminalTop = tester.getTopLeft(terminal).dy;
    final initialInputHeight = tester.getSize(inputBar).height;

    await tester.enterText(find.byType(TextField), 'a\nb\nc\nd\ne');
    await tester.pump();
    await tester.pump();

    expect(tester.getSize(inputBar).height, greaterThan(initialInputHeight));
    expect(tester.getSize(terminal), initialTerminalSize);
    expect(tester.getTopLeft(terminal).dy, lessThan(initialTerminalTop));
  });

  testWidgets('iPad-width buttons toggle left sidebar panels', (tester) async {
    final routes = await _pumpSession(tester, const Size(1024, 768));
    final initialPushes = routes.pushes;

    expect(find.byKey(const ValueKey('close-session-button')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sessions-sidebar-toggle')),
      findsOneWidget,
    );
    expect(find.byTooltip('Session menu'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('file-tree-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(routes.pushes, initialPushes);
    expect(find.byType(FileTreePanel), findsOneWidget);
    expect(find.byType(GitDiffPanel), findsNothing);

    await tester.tap(find.byKey(const ValueKey('git-diff-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(routes.pushes, initialPushes);
    expect(find.byType(FileTreePanel), findsOneWidget);
    expect(find.byType(GitDiffPanel), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(FileTreePanel)).dy,
      lessThan(tester.getTopLeft(find.byType(GitDiffPanel)).dy),
    );

    final initialSidebarWidth = tester
        .getSize(find.byType(FileTreePanel))
        .width;
    await tester.drag(
      find.byKey(const ValueKey('sidebar-horizontal-resize-handle')),
      const Offset(80, 0),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byType(FileTreePanel)).width,
      greaterThan(initialSidebarWidth),
    );

    final initialFileTreeHeight = tester
        .getSize(find.byType(FileTreePanel))
        .height;
    await tester.drag(
      find.byKey(const ValueKey('sidebar-vertical-resize-handle')),
      const Offset(0, 80),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byType(FileTreePanel)).height,
      greaterThan(initialFileTreeHeight),
    );

    await tester.tap(find.byKey(const ValueKey('file-tree-sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(FileTreePanel), findsNothing);
    expect(find.byType(GitDiffPanel), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('git-diff-sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(FileTreePanel), findsNothing);
    expect(find.byType(GitDiffPanel), findsNothing);
  });

  testWidgets('terminal directory links open that directory in desktop Files', (
    tester,
  ) async {
    final motif = _DirectoryLinkWorkspaceConnectionController();
    await _pumpSession(tester, const Size(1024, 768), motif: motif);

    final terminal = tester.widget<MotifTerminalView>(
      find.byKey(const ValueKey('terminal-pty-1')),
    );
    await terminal.onOpenFile!(
      const TerminalFileTarget(raw: 'docs', path: 'docs'),
    );
    await tester.pumpAndSettle();

    expect(motif.statPaths, ['/work/docs']);
    expect(motif.treePaths, contains('/work/docs'));
    expect(find.byType(FileTreePanel), findsOneWidget);
    expect(
      tester.widget<FileTreePanel>(find.byType(FileTreePanel)).root,
      '/work/docs',
    );
  });

  testWidgets('terminal directory links open that directory in mobile Files', (
    tester,
  ) async {
    final motif = _DirectoryLinkWorkspaceConnectionController();
    await _pumpSession(tester, const Size(700, 768), motif: motif);

    final terminal = tester.widget<MotifTerminalView>(
      find.byKey(const ValueKey('terminal-pty-1')),
    );
    await terminal.onOpenFile!(
      const TerminalFileTarget(raw: './docs', path: './docs'),
    );
    await tester.pumpAndSettle();

    expect(motif.statPaths, ['/work/docs']);
    expect(find.byKey(const ValueKey('mobile-files-drawer')), findsOneWidget);
    expect(find.byType(FileTreePanel), findsOneWidget);
    expect(
      tester.widget<FileTreePanel>(find.byType(FileTreePanel)).root,
      '/work/docs',
    );
  });

  testWidgets('iPad sidebar stacks sessions files and git diff panels', (
    tester,
  ) async {
    final motif = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session'),
      ];
    await _pumpSession(tester, const Size(1024, 768), motif: motif);

    await tester.tap(find.byKey(const ValueKey('sessions-sidebar-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-tree-sidebar-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('git-diff-sidebar-toggle')));
    await tester.pumpAndSettle();

    final sessions = find.byKey(const ValueKey('sidebar-session-list'));
    expect(sessions, findsOneWidget);
    expect(find.byType(FileTreePanel), findsOneWidget);
    expect(find.byType(GitDiffPanel), findsOneWidget);
    expect(
      tester.getTopLeft(sessions).dy,
      lessThan(tester.getTopLeft(find.byType(FileTreePanel)).dy),
    );
    expect(
      tester.getTopLeft(find.byType(FileTreePanel)).dy,
      lessThan(tester.getTopLeft(find.byType(GitDiffPanel)).dy),
    );

    final initialSidebarWidth = tester.getSize(sessions).width;
    await tester.drag(
      find.byKey(const ValueKey('sidebar-horizontal-resize-handle')),
      const Offset(80, 0),
    );
    await tester.pump();
    expect(tester.getSize(sessions).width, greaterThan(initialSidebarWidth));

    final initialSessionHeight = tester.getSize(sessions).height;
    await tester.drag(
      find.byKey(const ValueKey('sidebar-vertical-resize-handle')),
      const Offset(0, 80),
    );
    await tester.pump();
    expect(tester.getSize(sessions).height, greaterThan(initialSessionHeight));

    final initialFileTreeHeight = tester
        .getSize(find.byType(FileTreePanel))
        .height;
    await tester.drag(
      find.byKey(const ValueKey('sidebar-second-vertical-resize-handle')),
      const Offset(0, 80),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byType(FileTreePanel)).height,
      greaterThan(initialFileTreeHeight),
    );
  });

  testWidgets('sidebar closes with animation and shrinks to compact width', (
    tester,
  ) async {
    final motif = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session'),
      ];
    await _pumpSession(tester, const Size(1024, 768), motif: motif);

    await tester.tap(find.byKey(const ValueKey('sessions-sidebar-toggle')));
    await tester.pumpAndSettle();

    final sessions = find.byKey(const ValueKey('sidebar-session-list'));
    expect(sessions, findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('sidebar-horizontal-resize-handle')),
      const Offset(-300, 0),
    );
    await tester.pump();
    expect(tester.getSize(sessions).width, lessThan(120));

    await tester.tap(find.byKey(const ValueKey('sessions-sidebar-toggle')));
    await tester.pump();
    expect(sessions, findsOneWidget);

    await tester.pumpAndSettle();
    expect(sessions, findsNothing);
  });

  testWidgets('sidebar keyboard shortcuts toggle sessions files and git diff', (
    tester,
  ) async {
    final motif = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session'),
      ];
    await _pumpSession(tester, const Size(1024, 768), motif: motif);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyL, shift: true);
    expect(find.byKey(const ValueKey('sidebar-session-list')), findsOneWidget);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyE, shift: true);
    expect(find.byType(FileTreePanel), findsOneWidget);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyG, shift: true);
    expect(find.byType(GitDiffPanel), findsOneWidget);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyE, shift: true);
    expect(find.byType(FileTreePanel), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-session-list')), findsOneWidget);
    expect(find.byType(GitDiffPanel), findsOneWidget);
  });

  testWidgets('narrow buttons open file and git diff drawers', (tester) async {
    final motif = _GitDiffRouteWorkspaceConnectionController();
    final routes = await _pumpSession(
      tester,
      const Size(700, 768),
      motif: motif,
    );
    final initialPushes = routes.pushes;

    await tester.tap(find.byKey(const ValueKey('file-tree-sidebar-toggle')));
    await tester.pumpAndSettle();

    final scaffold = tester.state<ScaffoldState>(
      find.ancestor(
        of: find.byKey(const ValueKey('file-tree-sidebar-toggle')),
        matching: find.byType(Scaffold),
      ),
    );
    expect(routes.pushes, initialPushes);
    expect(scaffold.isEndDrawerOpen, isTrue);
    expect(find.byKey(const ValueKey('mobile-files-drawer')), findsOneWidget);
    expect(find.byType(FileTreePanel), findsOneWidget);

    scaffold.closeEndDrawer();
    await tester.pumpAndSettle();
    expect(scaffold.isEndDrawerOpen, isFalse);

    await tester.tap(find.byKey(const ValueKey('git-diff-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(routes.pushes, initialPushes);
    expect(scaffold.isEndDrawerOpen, isTrue);
    expect(
      find.byKey(const ValueKey('mobile-git-diff-drawer')),
      findsOneWidget,
    );
    expect(find.byType(GitDiffPanel), findsOneWidget);

    await tester.tap(find.byTooltip('Show diff'));
    await tester.pumpAndSettle();

    expect(routes.pushes, initialPushes + 1);
    expect(find.byType(GitDiffView), findsOneWidget);
    expect(find.text('+narrow route diff'), findsOneWidget);

    Navigator.of(tester.element(find.byType(GitDiffView))).pop();
    await tester.pumpAndSettle();

    expect(scaffold.isEndDrawerOpen, isFalse);
    expect(find.byType(GitDiffPanel), findsNothing);
  });

  testWidgets('narrow session menu opens a sessions drawer', (tester) async {
    final motif = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session', workdir: '~/next'),
      ];
    final next = _SessionMenuWorkspaceConnectionController(
      session: 'next-session',
      initiallyAttached: false,
    );
    final routes = await _pumpSession(
      tester,
      const Size(390, 844),
      motif: motif,
      workspaceConnectionFactory: (_, session) =>
          session == 'test-session' ? motif : next,
    );
    final initialPushes = routes.pushes;

    await tester.tap(find.byKey(const ValueKey('session-menu-button')));
    await tester.pumpAndSettle();

    final scaffold = tester.state<ScaffoldState>(
      find.ancestor(
        of: find.byKey(const ValueKey('session-menu-button')),
        matching: find.byType(Scaffold),
      ),
    );
    expect(routes.pushes, initialPushes);
    expect(scaffold.isDrawerOpen, isTrue);
    expect(
      find.byKey(const ValueKey('mobile-sessions-drawer')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('sidebar-session-list')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile-close-all-sessions')),
      findsOneWidget,
    );

    await tester.tap(find.text('next-session'));
    await tester.pumpAndSettle();

    expect(routes.pushes, initialPushes);
    expect(routes.replacements, 1);
    expect(next.attached, ['next-session']);
    expect(find.text('next-session'), findsWidgets);
  });

  testWidgets('close session pops without waiting for detach RPC', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final motif = _BlockingDetachWorkspaceConnectionController()
      ..sessions = const [SessionInfo(name: 'test-session')];
    addTearDown(() {
      if (!motif.detachCompleter.isCompleted) {
        motif.detachCompleter.complete();
      }
    });
    final app = await _appState(motif: motif);

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pump();

    Navigator.of(tester.element(find.text('home'))).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const SessionScreen(serverId: 'server-1', session: 'test-session'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('close-session-button')));
    await tester.pumpAndSettle();

    expect(motif.detaches, 1);
    expect(find.text('home'), findsOneWidget);
    expect(find.byType(SessionScreen), findsNothing);
  });

  testWidgets('close session detaches every connected session', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final current = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [SessionInfo(name: 'test-session')];
    final prod = _SessionMenuWorkspaceConnectionController(
      session: 'prod-session',
    )..sessions = const [SessionInfo(name: 'prod-session')];
    final app = await _appStateWith({'server-1': current, 'server-2': prod});
    app.workspaceForSession('server-2', 'prod-session');

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pump();

    Navigator.of(tester.element(find.text('home'))).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const SessionScreen(serverId: 'server-1', session: 'test-session'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('close-session-button')));
    await tester.pumpAndSettle();

    // Closes ALL open sessions, not just the current server's.
    expect(current.detaches, 1);
    expect(prod.detaches, 1);
    expect(find.text('home'), findsOneWidget);
    expect(find.byType(SessionScreen), findsNothing);
  });

  testWidgets('close session skips connected-but-unattached clients', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final current = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [SessionInfo(name: 'test-session')];
    final idle = _ConnectedNotAttachedWorkspaceConnectionController();
    final app = await _appStateWith({'server-1': current, 'server-2': idle});

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pump();

    Navigator.of(tester.element(find.text('home'))).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const SessionScreen(serverId: 'server-1', session: 'test-session'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('close-session-button')));
    await tester.pumpAndSettle();

    // The attached session detaches; the merely-connected one is left alone so
    // it can't raise a "missing X-Motif-Session" error.
    expect(current.detaches, 1);
    expect(idle.detaches, 0);
    expect(find.byType(SessionScreen), findsNothing);
  });

  testWidgets('terminal tab close prompts while a command is running', (
    tester,
  ) async {
    final motif = _RecordingWorkspaceConnectionController()
      ..views = const [
        ViewInfo(id: 'term-view', spec: PtyViewSpec('pty-1')),
        ViewInfo(id: 'other-view', spec: OtherViewSpec('notes')),
      ]
      ..activeViewId = 'other-view'
      ..runningCommand['pty-1'] = 'npm run dev';

    await _pumpSession(tester, const Size(1024, 768), motif: motif);

    await tester.tap(find.byKey(const ValueKey('close-tab-term-view')));
    await tester.pumpAndSettle();

    expect(find.text('Close running terminal?'), findsOneWidget);
    expect(
      find.text('A command is still running:\n\nnpm run dev'),
      findsOneWidget,
    );
    expect(motif.closedViews, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(motif.closedViews, isEmpty);

    await tester.tap(find.byKey(const ValueKey('close-tab-term-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close tab'));
    await tester.pump();

    expect(motif.closedViews, ['term-view']);
    expect(find.byKey(const ValueKey('close-tab-term-view')), findsNothing);
  });

  testWidgets('cancel close prompt preserves a nested session route', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final motif = _RecordingWorkspaceConnectionController()
      ..views = const [
        ViewInfo(id: 'term-view', spec: PtyViewSpec('pty-1')),
        ViewInfo(id: 'other-view', spec: OtherViewSpec('notes')),
      ]
      ..activeViewId = 'other-view'
      ..runningCommand['pty-1'] = 'codex';
    final app = await _appState(motif: motif);
    final nestedNavigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: Navigator(
            key: nestedNavigatorKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('session list')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    nestedNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const SessionScreen(serverId: 'server-1', session: 'test-session'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('close-tab-term-view')));
    await tester.pumpAndSettle();
    expect(find.text('Close running terminal?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Close running terminal?'), findsNothing);
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(motif.closedViews, isEmpty);
  });

  testWidgets('Chrome-style tab shortcuts create close and switch tabs', (
    tester,
  ) async {
    final motif = _ShortcutWorkspaceConnectionController()
      ..ptys = const [
        PtyInfo(id: 'pty-1', cols: 80, rows: 24),
        PtyInfo(id: 'pty-2', cols: 80, rows: 24),
        PtyInfo(id: 'pty-3', cols: 80, rows: 24),
      ]
      ..views = const [
        ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1')),
        ViewInfo(id: 'v2', spec: PtyViewSpec('pty-2')),
        ViewInfo(id: 'v3', spec: PtyViewSpec('pty-3')),
      ]
      ..activeViewId = 'v1';

    await _pumpSession(tester, const Size(1024, 768), motif: motif);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyT);
    expect(motif.createdPtys, 1);
    expect(motif.activeViewId, 'new-view-1');

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.digit1);
    expect(motif.activeViewId, 'v1');

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.digit2);
    expect(motif.activeViewId, 'v2');

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.digit9);
    expect(motif.activeViewId, 'new-view-1');

    await _sendControlShortcut(tester, LogicalKeyboardKey.tab, shift: true);
    expect(motif.activeViewId, 'v3');

    await _sendControlShortcut(tester, LogicalKeyboardKey.tab);
    expect(motif.activeViewId, 'new-view-1');

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyW);
    expect(motif.closedViews, ['new-view-1']);
  });

  testWidgets('large session panel omits create action and switches sessions', (
    tester,
  ) async {
    final motif = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session', workdir: '~/next'),
      ];
    final next = _SessionMenuWorkspaceConnectionController(
      session: 'next-session',
      initiallyAttached: false,
    );

    final routes = await _pumpSession(
      tester,
      const Size(1024, 768),
      motif: motif,
      workspaceConnectionFactory: (_, session) =>
          session == 'test-session' ? motif : next,
    );

    await tester.tap(find.byKey(const ValueKey('sessions-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Create session'), findsNothing);
    expect(find.text('New session'), findsNothing);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('SESSIONS'), findsNothing);
    expect(find.byKey(const ValueKey('sidebar-session-list')), findsOneWidget);
    expect(find.text('next-session'), findsOneWidget);

    await tester.tap(find.text('next-session'));
    await tester.pumpAndSettle();

    expect(motif.detaches, 1);
    expect(next.attached, ['next-session']);
    expect(routes.replacements, 1);
    expect(routes.lastReplacement, isA<PageRouteBuilder<void>>());
    expect(
      find.byKey(const ValueKey('sidebar-session-server-1-next-session')),
      findsOneWidget,
    );
  });

  testWidgets('sidebar panel state is shared while switching sessions', (
    tester,
  ) async {
    final motif = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session', workdir: '~/next'),
      ];
    final next = _SessionMenuWorkspaceConnectionController(
      session: 'next-session',
      initiallyAttached: false,
    );

    final routes = await _pumpSession(
      tester,
      const Size(1024, 768),
      motif: motif,
      workspaceConnectionFactory: (_, session) =>
          session == 'test-session' ? motif : next,
    );

    await tester.tap(find.byKey(const ValueKey('sessions-sidebar-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-tree-sidebar-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('git-diff-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sidebar-session-list')), findsOneWidget);
    expect(find.byType(FileTreePanel), findsOneWidget);
    expect(find.byType(GitDiffPanel), findsOneWidget);

    await tester.tap(find.text('next-session'));
    await tester.pumpAndSettle();

    expect(routes.replacements, 1);
    expect(find.byKey(const ValueKey('sidebar-session-list')), findsOneWidget);
    expect(find.byType(FileTreePanel), findsOneWidget);
    expect(find.byType(GitDiffPanel), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sidebar-session-server-1-next-session')),
      findsOneWidget,
    );
  });

  testWidgets('large session panel groups sessions across connected servers', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final current = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session'),
      ];
    final prod = _SessionMenuWorkspaceConnectionController(
      session: 'prod-session',
      initiallyAttached: false,
    )..sessions = const [SessionInfo(name: 'prod-session')];
    final app = await _appStateWith({'server-1': current, 'server-2': prod});

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const SessionScreen(
            serverId: 'server-1',
            session: 'test-session',
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('sessions-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sidebar-session-list')), findsOneWidget);
    expect(find.text('Dev'), findsOneWidget);
    expect(find.text('Prod'), findsOneWidget);
    expect(find.text('prod-session'), findsOneWidget);

    await app.servers.update(
      app.serverById('server-2')!.copyWith(name: 'Production'),
    );
    await tester.pump();
    expect(find.text('Prod'), findsNothing);
    expect(find.text('Production'), findsOneWidget);

    await tester.tap(find.text('prod-session'));
    await tester.pumpAndSettle();

    expect(current.detaches, 1);
    expect(prod.attached, ['prod-session']);
    expect(
      find.byKey(const ValueKey('sidebar-session-server-2-prod-session')),
      findsOneWidget,
    );
  });

  testWidgets('cross-server switch navigates before old detach completes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final current = _BlockingDetachWorkspaceConnectionController()
      ..sessions = const [SessionInfo(name: 'test-session')];
    final prod = _SessionMenuWorkspaceConnectionController(
      session: 'prod-session',
      initiallyAttached: false,
    )..sessions = const [SessionInfo(name: 'prod-session')];
    addTearDown(() {
      if (!current.detachCompleter.isCompleted) {
        current.detachCompleter.complete();
      }
    });
    final app = await _appStateWith({'server-1': current, 'server-2': prod});
    final routes = _RouteCounter();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          navigatorObservers: [routes],
          home: const SessionScreen(
            serverId: 'server-1',
            session: 'test-session',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sessions-sidebar-toggle')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('prod-session'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(current.detaches, 1);
    expect(current.detachCompleter.isCompleted, isFalse);
    expect(routes.replacements, 1);
    expect(prod.attached, ['prod-session']);
  });

  testWidgets('desktop keeps the previous server warm on cross-server switch', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final current = _SessionMenuWorkspaceConnectionController()
      ..sessions = const [SessionInfo(name: 'test-session')];
    final prod = _SessionMenuWorkspaceConnectionController(
      session: 'prod-session',
      initiallyAttached: false,
    )..sessions = const [SessionInfo(name: 'prod-session')];
    final app = await _appStateWith({
      'server-1': current,
      'server-2': prod,
    }, workspaceRetentionPolicy: const DesktopWorkspaceRetentionPolicy());

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const SessionScreen(
            serverId: 'server-1',
            session: 'test-session',
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('sessions-sidebar-toggle')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('prod-session'));
    await tester.pumpAndSettle();

    // The server we switched away from stays attached (warm) but drops to the
    // background; the target server attaches normally.
    expect(current.detaches, 0);
    expect(current.isForeground, isFalse);
    expect(prod.isForeground, isTrue);
    expect(prod.attached, ['prod-session']);
    expect(app.connectedWorkspaces.map((item) => item.connection).toSet(), {
      current,
      prod,
    });
  });

  testWidgets(
    'desktop keeps same-server sessions live and reuses them when switching back',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 768);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'other-session'),
      ];
      final current = _SessionMenuWorkspaceConnectionController()
        ..sessions = sessions;
      // A newly created desktop workspace has no session.list snapshot of its
      // own yet. Switching must carry over the server-level list so the prior
      // session remains available for switching back.
      final other = _SessionMenuWorkspaceConnectionController(
        session: 'other-session',
        initiallyAttached: false,
      );
      final app = await _appStateWith(
        {'server-1': current},
        workspaceRetentionPolicy: const DesktopWorkspaceRetentionPolicy(),
        workspaceConnectionFactory: (_, session) =>
            session == 'test-session' ? current : other,
      );

      await tester.pumpWidget(
        MotifScope(
          appState: app,
          child: MaterialApp(
            theme: motifTheme(Brightness.dark),
            home: const SessionScreen(
              serverId: 'server-1',
              session: 'test-session',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sessions-sidebar-toggle')));
      await tester.pumpAndSettle();
      final originalTerminal = tester.state(
        find.byKey(const ValueKey('terminal-pty-1')),
      );

      await tester.tap(find.text('other-session'));
      await tester.pumpAndSettle();

      expect(current.detaches, 0);
      expect(current.isForeground, isFalse);
      expect(other.attached, ['other-session']);
      expect(app.connectedWorkspaces.map((item) => item.connection).toSet(), {
        current,
        other,
      });
      expect(find.text('test-session'), findsOneWidget);

      await tester.tap(find.text('test-session'));
      await tester.pumpAndSettle();

      expect(other.detaches, 0);
      expect(other.isForeground, isFalse);
      expect(current.isForeground, isTrue);
      expect(current.attached, isEmpty);
      expect(
        app.workspaceForSession('server-1', 'test-session').connection,
        same(current),
      );
      expect(
        tester.state(find.byKey(const ValueKey('terminal-pty-1'))),
        same(originalTerminal),
      );

      await tester.tap(find.byKey(const ValueKey('close-session-button')));
      await tester.pump();
      expect(current.detaches, 1);
      expect(other.detaches, 1);
    },
  );

  test('desktop evicts the oldest warm workspace beyond its limit', () async {
    final sessions = [
      const SessionInfo(name: 'test-session'),
      for (var i = 2; i <= 5; i++) SessionInfo(name: 'session-$i'),
    ];
    final current = _SessionMenuWorkspaceConnectionController()
      ..sessions = sessions;
    final created = <_SessionMenuWorkspaceConnectionController>[];
    final app = await _appStateWith(
      {'server-1': current},
      workspaceRetentionPolicy: const DesktopWorkspaceRetentionPolicy(),
      workspaceConnectionFactory: (_, session) {
        if (session == 'test-session') return current;
        final client = _SessionMenuWorkspaceConnectionController(
          session: session,
        )..sessions = sessions;
        created.add(client);
        return client;
      },
    );
    addTearDown(app.dispose);

    app.workspaceForSession('server-1', 'test-session');
    for (var i = 2; i <= 5; i++) {
      app.workspaceForSession('server-1', 'session-$i');
    }
    await Future<void>.delayed(Duration.zero);

    expect(app.maxRetainedWorkspaces, 4);
    expect(app.connectedWorkspaces, hasLength(4));
    expect(current.disconnects, 1);
    expect(created.take(3).every((client) => client.disconnects == 0), isTrue);
  });
}
