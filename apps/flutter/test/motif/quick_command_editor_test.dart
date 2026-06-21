import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:motif/motif/ui/screens/quick_command_editor.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:provider/provider.dart';
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
    clientFactory: (_) => MotifClient(),
  );
}

Future<void> _pumpEditor(WidgetTester tester) async {
  final app = await _appState();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
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
}
