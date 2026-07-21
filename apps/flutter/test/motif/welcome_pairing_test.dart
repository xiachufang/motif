import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_server_transport.dart';

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
      serverTransportFactory: (_) => TestServerTransport(),
    );

    await tester.pumpWidget(MotifScope(appState: app, child: const MotifApp()));
    await tester.pump();

    expect(find.text('Scan or paste a pairing link'), findsOneWidget);

    await tester.tap(find.text('Scan or paste a pairing link'));
    await tester.pumpAndSettle();

    // The pairing sheet is up.
    expect(find.text('Pair with a server'), findsOneWidget);
  });
}
