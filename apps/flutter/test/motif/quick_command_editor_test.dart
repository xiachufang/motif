import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/terminal/terminal_key.dart';
import 'package:motif/motif/ui/screens/quick_command_editor.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_server_transport.dart';

Future<AppState> _appState() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices.defaults(),
    serverTransportFactory: (_) => TestServerTransport(),
  );
}

Future<AppState> _pumpEditor(WidgetTester tester) async {
  final app = await _appState();
  await tester.pumpWidget(
    MotifScope(
      appState: app,
      child: MaterialApp(
        theme: motifTheme(Brightness.light),
        home: const QuickCommandEditor(),
      ),
    ),
  );
  await tester.pump();
  return app;
}

Future<void> _openNewCommand(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Add command'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Key or text snippet'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('new command editor uses adaptive modal on desktop', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _pumpEditor(tester);

      await _openNewCommand(tester);

      expect(find.text('New command'), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('new command editor uses adaptive modal sheet on phones', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pumpEditor(tester);

      await _openNewCommand(tester);

      expect(find.text('New command'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('key picker persists a semantic key instead of ANSI bytes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final app = await _pumpEditor(tester);
      await _openNewCommand(tester);

      await tester.tap(find.text('Key'));
      await tester.pump();
      final chooseKey = find.text('Choose a key…');
      await tester.ensureVisible(chooseKey);
      await tester.pumpAndSettle();
      await tester.tap(chooseKey);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, '↑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final command = app.commands.commands.last;
      expect(command.kind, QuickCommandKind.key);
      expect(command.keyId, TerminalKeyIds.arrowUp);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
