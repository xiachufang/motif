import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/desktop_window.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/embedded/embedded_server_service.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_server_transport.dart';

TestServerTransport _smokeTransport() => TestServerTransport(
  onCall: (method, [params = const {}]) async =>
      method == 'session.list' ? const {'sessions': <Object?>[]} : const {},
);

class _RecordingDesktopWindowDelegate extends NoopDesktopWindowDelegate {
  int quitCalls = 0;

  @override
  Future<void> quit() async {
    quitCalls++;
  }
}

class _DelayedEmbeddedServerService extends EmbeddedServerService {
  _DelayedEmbeddedServerService()
    : super(
        available: true,
        config: const EmbeddedServerConfig(),
        status: const EmbeddedServerStatus(starting: true),
      );

  void becomeReady(int port) {
    statusState = EmbeddedServerStatus(
      running: true,
      boundAddrs: ['tcp://0.0.0.0:$port'],
    );
  }

  @override
  Future<void> updateConfig(EmbeddedServerConfig next) async {
    configState = next;
  }

  @override
  String generateToken() => '';

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<List<RegisteredPushToken>> registeredPushTokens() async => const [];

  @override
  Future<PushTestResult> sendTestPush(String deviceToken) async =>
      const PushTestResult(sent: false);

  @override
  List<String> tailLogs([int n = 200]) => const [];
}

void main() {
  testWidgets('first-run shows the welcome screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices.defaults(),
      serverTransportFactory: (_) => _smokeTransport(),
    );

    await tester.pumpWidget(MotifScope(appState: app, child: const MotifApp()));
    await tester.pump();

    expect(find.text('Welcome to motif'), findsOneWidget);
    expect(find.text('Connect a Server'), findsOneWidget);
  });

  testWidgets('with a configured server, shows the session browser', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"Dev box","host":"127.0.0.1","port":7777,"token":"","kind":"direct"}]',
      'activeServerID': 's1',
    });
    final prefs = await SharedPreferences.getInstance();
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices.defaults(),
      serverTransportFactory: (_) => _smokeTransport(),
    );

    await tester.pumpWidget(MotifScope(appState: app, child: const MotifApp()));
    await tester.pump();
    await tester.pump();

    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('Create session'), findsOneWidget);
    expect(app.isServerLive('s1'), isTrue);
  });

  testWidgets('newly added server does not auto-connect implicitly', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices.defaults(),
      serverTransportFactory: (_) => _smokeTransport(),
    );

    await tester.pumpWidget(MotifScope(appState: app, child: const MotifApp()));
    await tester.pump();
    expect(find.text('Welcome to motif'), findsOneWidget);

    await app.servers.add(
      const MotifServer(
        id: 's1',
        name: 'Dev box',
        host: '127.0.0.1',
        port: 7777,
        kind: ServerKind.direct,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Sessions'), findsOneWidget);
    expect(app.existingServerInstance('s1'), isNull);
  });

  test('startup local server waits for its embedded endpoint', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = listener.listen((socket) => socket.destroy());
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"embedded-local","name":"This computer",'
          '"host":"127.0.0.1","port":${listener.port},'
          '"token":"","kind":"direct"}]',
      'activeServerID': 'embedded-local',
    });
    final prefs = await SharedPreferences.getInstance();
    final embedded = _DelayedEmbeddedServerService();
    final transport = _smokeTransport();
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices.defaults(),
      embeddedServer: embedded,
      serverTransportFactory: (_) => transport,
    );
    addTearDown(() async {
      app.dispose();
      await accepted.cancel();
      await listener.close();
    });

    await app.autoConnectStartupServer();
    expect(transport.connectCalls, 0);

    embedded.becomeReady(listener.port);
    for (
      var attempt = 0;
      attempt < 100 && transport.connectCalls == 0;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(transport.connectCalls, 1);
    expect(app.isServerLive(kEmbeddedServerId), isTrue);
    expect(app.serverById(kEmbeddedServerId)?.port, listener.port);
  });

  testWidgets('command q quits the complete macOS app', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final desktop = _RecordingDesktopWindowDelegate();
    DesktopWindow.install(desktop);
    try {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final app = AppState(
        servers: ServerStore(prefs),
        terminalSettings: TerminalSettingsStore(prefs),
        commands: QuickCommandStore(prefs),
        push: PushSettingsStore(prefs),
        platform: PlatformServices.defaults(),
      );
      addTearDown(app.dispose);

      await tester.pumpWidget(
        MotifScope(appState: app, child: const MotifApp()),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(desktop.quitCalls, 1);
    } finally {
      DesktopWindow.install(const NoopDesktopWindowDelegate());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
