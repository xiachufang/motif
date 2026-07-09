import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:motif/motif/ui/screens/session_screen.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/notification_banner.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NotifMotifClient extends MotifClient {
  @override
  MotifConnState get state => const ConnAttached('work');

  @override
  bool get isLive => true;

  @override
  Future<void> attach(String name) async {}

  @override
  Future<void> refreshSessions() async {}
}

Future<AppState> _appWithClient(MotifClient client) async {
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
    clientFactory: (_) => client,
  );
  app.clientForServer('server-1');
  return app;
}

void main() {
  test('requestOpenSession stores pending and switches to client mode', () async {
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
  });

  testWidgets('banner tap opens the named session', (tester) async {
    final client = _NotifMotifClient()
      ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
      ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
      ..activeViewId = 'v1';
    final app = await _appWithClient(client);
    addTearDown(app.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MotifApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(app.hasActiveServer, isTrue);
    expect(find.byType(SessionScreen), findsNothing);

    client.showNotification(
      const MotifNotification(
        title: 'Command finished',
        body: 'make test',
        sessionId: 'work',
        kind: 'finished',
      ),
    );
    await tester.pump();

    expect(find.text('Command finished'), findsOneWidget);
    await tester.tap(find.text('Command finished'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SessionScreen), findsOneWidget);
    expect(client.latestNotification, isNull);
    final screen = tester.widget<SessionScreen>(find.byType(SessionScreen));
    expect(screen.serverId, 'server-1');
    expect(screen.session, 'work');
  });

  testWidgets('banner tap without sessionId only dismisses', (tester) async {
    final client = _NotifMotifClient();
    final app = await _appWithClient(client);
    addTearDown(app.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
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

    client.showNotification(
      const MotifNotification(
        title: 'Ping',
        body: 'hello',
        sessionId: null,
        kind: 'info',
      ),
    );
    await tester.pump();
    expect(find.text('Ping'), findsOneWidget);

    await tester.tap(find.text('Ping'));
    await tester.pump();

    expect(client.latestNotification, isNull);
    expect(app.pendingSessionOpen, isNull);
    expect(find.text('home'), findsOneWidget);
  });
}
