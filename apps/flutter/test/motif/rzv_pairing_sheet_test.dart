import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rzv/pairing_payload.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/ui/screens/rzv_pairing_sheet.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppState> _appState() async {
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

Future<void> _pumpHost(
  WidgetTester tester,
  AppState app, {
  required void Function(BuildContext context) onOpen,
}) {
  return tester.pumpWidget(
    MotifScope(
      appState: app,
      child: MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => onOpen(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

String _validLink() => MotifPairingPayload(
  relay: 'relay.example:9999',
  psk: Uint8List.fromList(List.generate(32, (i) => i)),
  name: 'studio',
).toUri();

void main() {
  testWidgets('pasting a valid link pairs a rendezvous server', (tester) async {
    final app = await _appState();
    await _pumpHost(
      tester,
      app,
      onOpen: (context) => showRzvPairingSheet(context),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), _validLink());
    await tester.pumpAndSettle();

    // Preview reflects the parsed payload (plaintext here — no pk).
    expect(find.textContaining('studio'), findsWidgets);

    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(app.servers.servers, hasLength(1));
    final s = app.servers.servers.single;
    expect(s.kind, ServerKind.rendezvous);
    expect(s.relay, 'relay.example:9999');
    expect(s.name, 'studio');
  });

  testWidgets('an invalid link keeps Pair disabled and adds nothing', (
    tester,
  ) async {
    final app = await _appState();
    await _pumpHost(
      tester,
      app,
      onOpen: (context) => showRzvPairingSheet(context),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'https://nope');
    await tester.pumpAndSettle();

    final pairButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Pair'),
    );
    expect(pairButton.onPressed, isNull, reason: 'Pair disabled for bad link');
    expect(app.servers.servers, isEmpty);
  });
}
