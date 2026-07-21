import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/persistence/stores.dart';
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

Future<void> _pumpEditor(WidgetTester tester) async {
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
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.scrollPhysics?.allowUserScrolling, isFalse);
        expect(field.scrollPhysics?.allowImplicitScrolling, isTrue);
      }
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
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.scrollPhysics, isNull);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
