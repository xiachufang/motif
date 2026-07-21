import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_controller.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_view_model.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:motif/motif/ui/screens/session_screen.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/notification_banner.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_server_transport.dart';
import 'support/workspace_connection_fixture.dart';

class _NotifWorkspaceConnectionController
    extends WorkspaceConnectionController {
  _NotifWorkspaceConnectionController({String session = 'work'})
    : super(session: session) {
    updateConnectionState(ConnAttached(session), live: true);
  }

  @override
  Future<void> attach() async {}
}

class _ConnectingNotifWorkspaceConnectionController
    extends WorkspaceConnectionController {
  final Completer<void> connectGate = Completer<void>();
  final List<String> attachedSessions = [];
  int connectCalls = 0;

  _ConnectingNotifWorkspaceConnectionController({
    super.session = 'cold-start',
  }) {
    ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)];
    views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))];
    activeViewId = 'v1';
  }

  @override
  Future<void> connect(
    MotifServer server, {
    bool force = false,
    ProxySettings proxy = ProxySettings.none,
    Uint8List? certPin,
  }) async {
    connectCalls++;
    updateConnectionState(const ConnConnecting(), live: false);
    await connectGate.future;
    updateConnectionState(const ConnConnected(), live: true);
  }

  @override
  Future<void> attach() async {
    attachedSessions.add(session);
    updateConnectionState(ConnAttached(session), live: true);
  }
}

Future<AppState> _appWithClient(WorkspaceConnectionController client) async {
  SharedPreferences.setMockInitialValues({
    'motif.servers.v1':
        '[{"id":"server-1","name":"Dev","host":"127.0.0.1","port":7777,"token":"","kind":"direct"}]',
    'activeServerID': 'server-1',
  });
  final prefs = await SharedPreferences.getInstance();
  final app = AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices.defaults(),
    serverTransportFactory: (_) => TestServerTransport(
      live: client is! _ConnectingNotifWorkspaceConnectionController,
      onConnect: client is _ConnectingNotifWorkspaceConnectionController
          ? (
              transport,
              server, {
              required force,
              required proxy,
              certPin,
            }) async {
              await client.connectGate.future;
              return const PingInfo(service: 'motif-server', version: 'test');
            }
          : null,
      onCall: (method, [params = const {}]) async =>
          method == 'session.list' ? const {'sessions': <Object?>[]} : const {},
    ),
    workspaceConnectionFactory: (_, session) => session == client.session
        ? client
        : _NotifWorkspaceConnectionController(session: session),
  );
  app.serverInstance('server-1');
  return app;
}

void main() {
  test(
    'requestOpenSession stores pending and switches to client mode',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final app = AppState(
        servers: ServerStore(prefs),
        terminalSettings: TerminalSettingsStore(prefs),
        commands: QuickCommandStore(prefs),
        push: PushSettingsStore(prefs),
        platform: PlatformServices.defaults(),
      );
      app.setViewMode(AppViewMode.server);

      app.requestOpenSession(serverId: 'server-1', session: 'work');

      expect(app.viewMode, AppViewMode.client);
      expect(app.pendingSessionOpen?.serverId, 'server-1');
      expect(app.pendingSessionOpen?.session, 'work');
      expect(app.takePendingSessionOpen()?.session, 'work');
      expect(app.pendingSessionOpen, isNull);
    },
  );

  testWidgets('banner tap opens the named session', (tester) async {
    final client = _NotifWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';
    final app = await _appWithClient(client);
    addTearDown(app.dispose);
    final workspace = app.workspaceForSession('server-1', 'work');

    await tester.pumpWidget(MotifScope(appState: app, child: const MotifApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(app.hasActiveServer, isTrue);
    expect(find.byType(SessionScreen), findsNothing);

    workspace.viewModel.presence.latestNotification = const MotifNotification(
      title: 'Command finished',
      body: 'make test',
      sessionId: 'work',
      kind: 'finished',
    );
    await tester.pump();

    expect(find.text('Command finished'), findsOneWidget);
    await tester.tap(find.text('Command finished'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SessionScreen), findsOneWidget);
    expect(workspace.viewModel.presence.latestNotification, isNull);
    final screen = tester.widget<SessionScreen>(find.byType(SessionScreen));
    expect(screen.serverId, 'server-1');
    expect(screen.session, 'work');
  });

  testWidgets('banner tap without sessionId only dismisses', (tester) async {
    final client = _NotifWorkspaceConnectionController();
    final app = await _appWithClient(client);
    addTearDown(app.dispose);
    final workspace = app.workspaceForSession('server-1', 'work');

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: NotificationBannerHost(
            app: app,
            child: const Scaffold(body: Text('home')),
          ),
        ),
      ),
    );
    await tester.pump();

    workspace.viewModel.presence.latestNotification = const MotifNotification(
      title: 'Ping',
      body: 'hello',
      sessionId: null,
      kind: 'info',
    );
    await tester.pump();
    expect(find.text('Ping'), findsOneWidget);

    await tester.tap(find.text('Ping'));
    await tester.pump();

    expect(workspace.viewModel.presence.latestNotification, isNull);
    expect(app.pendingSessionOpen, isNull);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('notification waits for a disconnected server before opening', (
    tester,
  ) async {
    final client = _ConnectingNotifWorkspaceConnectionController();
    final app = await _appWithClient(client);
    addTearDown(app.dispose);
    app.requestOpenSession(serverId: 'server-1', session: 'cold-start');

    await tester.pumpWidget(MotifScope(appState: app, child: const MotifApp()));
    await tester.pump();
    await tester.pump();

    final serverTransport =
        app.existingServerInstance('server-1')!.transport
            as TestServerTransport;
    expect(serverTransport.connectCalls, 1);
    expect(client.connectCalls, 0);
    expect(find.byType(SessionScreen), findsNothing);

    client.connectGate.complete();
    await tester.pumpAndSettle();

    expect(find.byType(SessionScreen), findsOneWidget);
    expect(client.connectCalls, 1);
    final screen = tester.widget<SessionScreen>(find.byType(SessionScreen));
    expect(screen.session, 'cold-start');
    expect(client.attachedSessions, ['cold-start']);
  });

  testWidgets('a second notification replaces the visible session', (
    tester,
  ) async {
    final client = _NotifWorkspaceConnectionController()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';
    final app = await _appWithClient(client);
    addTearDown(app.dispose);

    await tester.pumpWidget(MotifScope(appState: app, child: const MotifApp()));
    await tester.pump();

    app.requestOpenSession(serverId: 'server-1', session: 'first');
    await tester.pumpAndSettle();
    expect(
      tester.widget<SessionScreen>(find.byType(SessionScreen)).session,
      'first',
    );

    app.requestOpenSession(serverId: 'server-1', session: 'second');
    await tester.pumpAndSettle();

    expect(find.byType(SessionScreen), findsOneWidget);
    expect(
      tester.widget<SessionScreen>(find.byType(SessionScreen)).session,
      'second',
    );
    expect(app.pendingSessionOpen, isNull);
  });
}
