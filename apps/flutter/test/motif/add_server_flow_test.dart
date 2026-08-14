import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/ui/screens/add_server_flow.dart';
import 'package:motif/motif/ui/screens/rzv_scan_screen.dart';
import 'package:motif/motif/ui/screens/server_edit_sheet.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
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

String _key(int seed) => base64Url
    .encode(Uint8List.fromList(List.generate(32, (index) => seed + index)))
    .replaceAll('=', '');

void main() {
  testWidgets(
    'scan choice adds the pairing server without an intermediate form',
    (tester) async {
      final app = await _appState();
      final link = Uri(
        scheme: 'motif',
        host: 'pair',
        queryParameters: {
          'v': '1',
          'rzv': 'relay.example.com:9999',
          'psk': _key(1),
          'name': 'Scanned Relay',
        },
      ).toString();
      ServerEditResult? result;

      await tester.pumpWidget(
        MotifScope(
          appState: app,
          child: MaterialApp(
            theme: motifTheme(Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showAddServerFlow(
                      context,
                      scanSupported: true,
                      scanLauncher: (_) async => RzvScannedLink(link),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Scan QR Code'), findsOneWidget);
      expect(find.text('Enter Manually'), findsOneWidget);

      await tester.tap(find.text('Scan QR Code'));
      await tester.pumpAndSettle();

      expect(app.servers.servers, hasLength(1));
      expect(app.servers.servers.single.kind, ServerKind.rendezvous);
      expect(app.servers.servers.single.name, 'Scanned Relay');
      expect(result?.connectAfterSave, isTrue);
      expect(find.byType(ServerEditSheet), findsNothing);
    },
  );

  testWidgets('manual choice opens the existing server form', (tester) async {
    final app = await _appState();
    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    unawaited(showAddServerFlow(context, scanSupported: true)),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter Manually'));
    await tester.pumpAndSettle();

    expect(find.byType(ServerEditSheet), findsOneWidget);
    expect(find.text('Relay'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Save and Connect'),
      findsOneWidget,
    );
  });

  testWidgets('camera fallback opens manual entry with Relay selected', (
    tester,
  ) async {
    final app = await _appState();
    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  showAddServerFlow(
                    context,
                    scanSupported: true,
                    scanLauncher: (_) async => const RzvScanManualEntry(),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan QR Code'));
    await tester.pumpAndSettle();

    expect(find.byType(ServerEditSheet), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Pairing Link',
      ),
      findsOneWidget,
    );
  });
}
