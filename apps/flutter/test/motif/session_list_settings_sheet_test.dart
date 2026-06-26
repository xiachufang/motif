import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/ui/screens/session_list_settings_sheet.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');

  testWidgets('shows push notifications and log export settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final app = await AppState.load();
    addTearDown(app.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: const Scaffold(body: SessionListSettingsSheet()),
        ),
      ),
    );

    expect(find.text('Push notifications'), findsOneWidget);
    expect(find.text('Export logs'), findsOneWidget);
  });

  testWidgets('shares exported logs on mobile platforms', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final root = await Directory.systemTemp.createTemp(
      'motif-settings-share-test.',
    );
    final support = Directory('${root.path}/support');
    final downloads = Directory('${root.path}/downloads');
    final temp = Directory('${root.path}/tmp');
    final shareCalls = <MethodCall>[];

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async {
        return switch (call.method) {
          'getApplicationSupportDirectory' => support.path,
          'getDownloadsDirectory' => downloads.path,
          'getTemporaryDirectory' => temp.path,
          _ => null,
        };
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      shareChannel,
      (call) async {
        shareCalls.add(call);
        return 'dev.fluttercommunity.plus/share/unavailable';
      },
    );

    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProviderChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        shareChannel,
        null,
      );
      if (await root.exists()) await root.delete(recursive: true);
    });

    SharedPreferences.setMockInitialValues({});
    final app = await AppState.load();
    addTearDown(app.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: const Scaffold(body: SessionListSettingsSheet()),
        ),
      ),
    );

    await tester.tap(find.text('Export logs'));
    for (var i = 0; i < 20 && shareCalls.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(shareCalls, hasLength(1));
    expect(shareCalls.single.method, 'share');
    final args = shareCalls.single.arguments as Map<Object?, Object?>;
    expect(args['title'], 'Motif logs');
    expect(args['subject'], 'Motif logs');
    expect(args['paths'], isA<List<Object?>>());
    expect((args['paths'] as List<Object?>).single, startsWith(downloads.path));
    expect(args['mimeTypes'], <String>['text/plain']);
  });
}
