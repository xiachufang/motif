import 'dart:typed_data';

import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SmokeMotifClient extends MotifClient {
  bool _live = false;

  @override
  bool get isLive => _live;

  @override
  Future<void> connect(
    MotifServer server, {
    bool force = false,
    ProxySettings proxy = ProxySettings.none,
    Uint8List? certPin,
  }) async {
    _live = true;
    notifyListeners();
  }
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
      clientFactory: (_) => _SmokeMotifClient(),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const MotifApp()),
    );
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
      clientFactory: (_) => _SmokeMotifClient(),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const MotifApp()),
    );
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
      clientFactory: (_) => _SmokeMotifClient(),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const MotifApp()),
    );
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
    expect(app.existingClientForServer('s1'), isNull);
  });
}
