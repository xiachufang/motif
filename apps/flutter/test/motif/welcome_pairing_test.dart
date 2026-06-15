import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubClient extends MotifClient {
  @override
  Future<void> connect(
    MotifServer server, {
    bool force = false,
    ProxySettings proxy = ProxySettings.none,
    Uint8List? certPin,
  }) async {}
}

void main() {
  testWidgets('first-run welcome screen can open the pairing sheet', (
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
      clientFactory: (_) => _StubClient(),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const MotifApp()),
    );
    await tester.pump();

    expect(find.text('Scan or paste a pairing link'), findsOneWidget);

    await tester.tap(find.text('Scan or paste a pairing link'));
    await tester.pumpAndSettle();

    // The pairing sheet is up.
    expect(find.text('Pair with a server'), findsOneWidget);
  });
}
