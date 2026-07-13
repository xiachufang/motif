import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/macos_permissions.dart';
import 'package:motif/motif/platform/secret_store.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/ui/screens/session_list_settings_sheet.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows push notifications and log export settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final app = await AppState.load(
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: NoopPushService(),
        secrets: MemorySecretStore(),
      ),
    );
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

  testWidgets('shows and operates macOS permissions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final permissions = _FakeMacosPermissions({
      MacosPermission.fullDiskAccess: MacosPermissionStatus.managedExternally,
      MacosPermission.screenRecording: MacosPermissionStatus.notGranted,
      MacosPermission.accessibility: MacosPermissionStatus.granted,
    });
    final app = await _pumpSettings(tester, macosPermissions: permissions);
    addTearDown(app.dispose);

    expect(find.text('Full Disk Access'), findsOneWidget);
    expect(find.text('Screen Recording'), findsOneWidget);
    expect(find.text('Accessibility'), findsOneWidget);
    expect(find.text('Automation'), findsOneWidget);
    expect(find.text('Managed in System Settings'), findsNWidgets(2));
    expect(find.text('Not allowed'), findsOneWidget);
    expect(find.text('Allowed'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('macos-permission-screenRecording')),
    );
    await tester.pump();
    expect(permissions.requested, [MacosPermission.screenRecording]);
    expect(find.text('Allowed'), findsNWidgets(2));

    await tester.tap(
      find.byKey(const ValueKey('macos-permission-fullDiskAccess')),
    );
    await tester.pump();
    expect(permissions.opened, [MacosPermission.fullDiskAccess]);

    await tester.tap(find.byKey(const ValueKey('macos-permission-automation')));
    await tester.pump();
    expect(permissions.opened, [
      MacosPermission.fullDiskAccess,
      MacosPermission.automation,
    ]);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('refreshes macOS permissions manually and on resume', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final permissions = _FakeMacosPermissions({
      MacosPermission.fullDiskAccess: MacosPermissionStatus.managedExternally,
      MacosPermission.screenRecording: MacosPermissionStatus.notGranted,
      MacosPermission.accessibility: MacosPermissionStatus.notGranted,
    });
    final app = await _pumpSettings(tester, macosPermissions: permissions);
    addTearDown(app.dispose);
    expect(permissions.statusCalls, 1);

    await tester.tap(find.byKey(const ValueKey('refresh-macos-permissions')));
    await tester.pump();
    expect(permissions.statusCalls, 2);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(permissions.statusCalls, 3);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('hides macOS permissions on other platforms', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final permissions = _FakeMacosPermissions(const {});
    final app = await _pumpSettings(tester, macosPermissions: permissions);
    addTearDown(app.dispose);

    expect(find.text('Full Disk Access'), findsNothing);
    expect(find.text('Screen Recording'), findsNothing);
    expect(find.text('Accessibility'), findsNothing);
    expect(find.text('Automation'), findsNothing);
    expect(permissions.statusCalls, 0);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('keeps settings usable when permission loading fails', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final permissions = _FakeMacosPermissions(const {})..loadError = true;
    final app = await _pumpSettings(tester, macosPermissions: permissions);
    addTearDown(app.dispose);

    expect(find.textContaining('Could not load macOS permissions'), findsOne);
    expect(find.text('Push notifications'), findsOneWidget);
    expect(find.text('Export logs'), findsOneWidget);
    expect(find.text('Unavailable'), findsNWidgets(2));
    expect(find.text('Managed in System Settings'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 3));
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<AppState> _pumpSettings(
  WidgetTester tester, {
  required MacosPermissions macosPermissions,
}) async {
  SharedPreferences.setMockInitialValues({});
  final app = await AppState.load(
    platform: PlatformServices(
      tailscale: NoopTailscaleService(),
      speech: NoopSpeechService(),
      push: NoopPushService(),
      secrets: MemorySecretStore(),
    ),
  );
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: SessionListSettingsSheet(macosPermissions: macosPermissions),
        ),
      ),
    ),
  );
  await tester.pump();
  return app;
}

class _FakeMacosPermissions implements MacosPermissions {
  _FakeMacosPermissions(this.statuses);

  final MacosPermissionStatuses statuses;
  final List<MacosPermission> requested = [];
  final List<MacosPermission> opened = [];
  int statusCalls = 0;
  bool loadError = false;

  @override
  Future<MacosPermissionStatuses> getStatuses() async {
    statusCalls++;
    if (loadError) throw StateError('permission service unavailable');
    return Map.of(statuses);
  }

  @override
  Future<void> openSystemSettings(MacosPermission permission) async {
    opened.add(permission);
  }

  @override
  Future<MacosPermissionStatus> request(MacosPermission permission) async {
    requested.add(permission);
    statuses[permission] = MacosPermissionStatus.granted;
    return MacosPermissionStatus.granted;
  }
}
