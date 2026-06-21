import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:motif/motif/terminal/terminal_input.dart';
import 'package:motif/motif/ui/screens/file_tree_panel.dart';
import 'package:motif/motif/ui/screens/git_diff_panel.dart';
import 'package:motif/motif/ui/screens/session_screen.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _RecordingMotifClient extends MotifClient {
  final List<String> closedViews = [];

  @override
  Future<void> closeView(String viewId) async {
    closedViews.add(viewId);
    await super.closeView(viewId);
  }
}

class _SessionMenuMotifClient extends MotifClient {
  final List<String> attached = [];
  int detaches = 0;

  @override
  MotifConnState get state => const ConnAttached('test-session');

  @override
  bool get isLive => true;

  @override
  Future<void> refreshSessions() async {}

  @override
  Future<void> detach() async {
    detaches++;
  }

  @override
  Future<void> attach(String name) async {
    attached.add(name);
  }
}

class _BlockingDetachMotifClient extends _SessionMenuMotifClient {
  final Completer<void> detachCompleter = Completer<void>();

  @override
  Future<void> detach() async {
    detaches++;
    await detachCompleter.future;
  }
}

/// Connected to a server but not attached to any session — `session.detach`
/// would be rejected server-side, so close-all must skip it.
class _ConnectedNotAttachedMotifClient extends _SessionMenuMotifClient {
  @override
  MotifConnState get state => const ConnConnected();
}

class _ShortcutMotifClient extends MotifClient {
  int createdPtys = 0;
  final List<String> closedViews = [];

  @override
  MotifConnState get state => const ConnAttached('test-session');

  @override
  bool get isLive => true;

  @override
  Future<PtyInfo> createPty({
    String? cmd,
    String? cwd,
    required int cols,
    required int rows,
  }) async {
    createdPtys++;
    final pty = PtyInfo(id: 'new-pty-$createdPtys', cols: cols, rows: rows);
    final view = ViewInfo(
      id: 'new-view-$createdPtys',
      spec: PtyViewSpec(pty.id),
    );
    ptys = [...ptys, pty];
    views = [...views, view];
    activeViewId = view.id;
    notifyListeners();
    return pty;
  }

  @override
  Future<void> closeView(String viewId) async {
    closedViews.add(viewId);
    views = [
      for (final view in views)
        if (view.id != viewId) view,
    ];
    if (activeViewId == viewId) activeViewId = views.firstOrNull?.id;
    notifyListeners();
  }

  @override
  Future<void> activateView(String? viewId) async {
    if (viewId == null) return;
    activeViewId = viewId;
    notifyListeners();
  }
}

class _SuspendedMotifClient extends _ShortcutMotifClient {
  MotifConnState _state = const ConnSuspended(
    'Tailscale disconnected',
    session: 'test-session',
  );

  @override
  MotifConnState get state => _state;

  @override
  bool get isLive => false;

  void emitSuspended() {
    _state = const ConnSuspended(
      'Tailscale disconnected',
      session: 'test-session',
    );
    notifyListeners();
  }
}

Future<AppState> _appStateWith(Map<String, MotifClient> clients) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final app = AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices.defaults(),
    clientFactory: (server) => clients[server.id] ?? MotifClient(),
  );
  for (final entry in clients.entries) {
    await app.servers.add(
      MotifServer(
        id: entry.key,
        name: entry.key == 'server-1' ? 'Dev' : 'Prod',
        host: '127.0.0.1',
      ),
    );
    app.clientForServer(entry.key);
  }
  return app;
}

Future<AppState> _appState({MotifClient? motif}) {
  return _appStateWith({'server-1': motif ?? MotifClient()});
}

Future<_RouteCounter> _pumpSession(
  WidgetTester tester,
  Size size, {
  MotifClient? motif,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final app = await _appState(motif: motif);
  final routes = _RouteCounter();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
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
    final motif = _ShortcutMotifClient()
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

  testWidgets('Android push transition mounts terminal pane immediately', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final motif = _ShortcutMotifClient()
        ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
        ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
        ..activeViewId = 'v1';
      final app = await _appState(motif: motif);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
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
      final motif = _ShortcutMotifClient()
        ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
        ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
        ..activeViewId = 'v1';
      final app = await _appState(motif: motif);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
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
    final motif = _SuspendedMotifClient()
      ..intendedSession = 'test-session'
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
    final motif = _ShortcutMotifClient()
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

  testWidgets('bottom input state is scoped to the active tab', (tester) async {
    final motif = _ShortcutMotifClient()
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
    expect(inputField().hintLocales, terminalEnglishHintLocales);

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

  testWidgets('iPad sidebar stacks sessions files and git diff panels', (
    tester,
  ) async {
    final motif = _SessionMenuMotifClient()
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
    final motif = _SessionMenuMotifClient()
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
    final motif = _SessionMenuMotifClient()
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

  testWidgets('narrow buttons keep opening pages', (tester) async {
    final routes = await _pumpSession(tester, const Size(700, 768));
    final initialPushes = routes.pushes;

    await tester.tap(find.byKey(const ValueKey('file-tree-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(routes.pushes, initialPushes + 1);
    expect(find.byType(FileTreePanel), findsOneWidget);

    Navigator.of(tester.element(find.byType(FileTreePanel))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('git-diff-sidebar-toggle')));
    await tester.pumpAndSettle();

    expect(routes.pushes, initialPushes + 2);
    expect(find.byType(GitDiffPanel), findsOneWidget);
  });

  testWidgets('close session pops without waiting for detach RPC', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final motif = _BlockingDetachMotifClient()
      ..sessions = const [SessionInfo(name: 'test-session')];
    addTearDown(() {
      if (!motif.detachCompleter.isCompleted) {
        motif.detachCompleter.complete();
      }
    });
    final app = await _appState(motif: motif);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
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

    final current = _SessionMenuMotifClient()
      ..sessions = const [SessionInfo(name: 'test-session')];
    final prod = _SessionMenuMotifClient()
      ..sessions = const [SessionInfo(name: 'prod-session')];
    final app = await _appStateWith({'server-1': current, 'server-2': prod});

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
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

    final current = _SessionMenuMotifClient()
      ..sessions = const [SessionInfo(name: 'test-session')];
    final idle = _ConnectedNotAttachedMotifClient();
    final app = await _appStateWith({'server-1': current, 'server-2': idle});

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
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
    final motif = _RecordingMotifClient()
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

  testWidgets('Chrome-style tab shortcuts create close and switch tabs', (
    tester,
  ) async {
    final motif = _ShortcutMotifClient()
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
    final motif = _SessionMenuMotifClient()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session', workdir: '~/next'),
      ];

    final routes = await _pumpSession(
      tester,
      const Size(1024, 768),
      motif: motif,
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
    expect(motif.attached, ['next-session']);
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
    final motif = _SessionMenuMotifClient()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session', workdir: '~/next'),
      ];

    final routes = await _pumpSession(
      tester,
      const Size(1024, 768),
      motif: motif,
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

    final current = _SessionMenuMotifClient()
      ..sessions = const [
        SessionInfo(name: 'test-session'),
        SessionInfo(name: 'next-session'),
      ];
    final prod = _SessionMenuMotifClient()
      ..sessions = const [SessionInfo(name: 'prod-session')];
    final app = await _appStateWith({'server-1': current, 'server-2': prod});

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
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

    await tester.tap(find.text('prod-session'));
    await tester.pumpAndSettle();

    expect(current.detaches, 1);
    expect(prod.attached, ['prod-session']);
    expect(
      find.byKey(const ValueKey('sidebar-session-server-2-prod-session')),
      findsOneWidget,
    );
  });
}
