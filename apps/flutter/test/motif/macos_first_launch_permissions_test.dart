import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/macos_first_launch_permissions.dart';
import 'package:motif/motif/platform/macos_permissions.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'requests every missing permission once and in a stable order',
    () async {
      final preferences = SharedPreferences.getInstance();
      final permissions = _FakeMacosPermissions({
        for (final permission in MacosPermission.values)
          permission: MacosPermissionStatus.notGranted,
      });
      final coordinator = MacosFirstLaunchPermissions(
        permissions: permissions,
        preferences: preferences,
        supported: true,
      );

      await coordinator.requestIfNeeded();
      await coordinator.requestIfNeeded();

      expect(permissions.statusCalls, 1);
      expect(permissions.requested, const [
        MacosPermission.screenRecording,
        MacosPermission.automation,
        MacosPermission.homeDirectory,
        MacosPermission.accessibility,
      ]);
      expect(
        (await preferences).getBool(kMacosInitialPermissionsRequestedKey),
        isTrue,
      );
    },
  );

  test('does not request permissions again after a relaunch', () async {
    SharedPreferences.setMockInitialValues({
      kMacosInitialPermissionsRequestedKey: true,
    });
    final permissions = _FakeMacosPermissions(const {});

    await MacosFirstLaunchPermissions(
      permissions: permissions,
      preferences: SharedPreferences.getInstance(),
      supported: true,
    ).requestIfNeeded();

    expect(permissions.statusCalls, 0);
    expect(permissions.requested, isEmpty);
  });

  test('skips permissions that are already granted', () async {
    final permissions = _FakeMacosPermissions({
      MacosPermission.screenRecording: MacosPermissionStatus.granted,
      MacosPermission.automation: MacosPermissionStatus.notGranted,
      MacosPermission.homeDirectory: MacosPermissionStatus.notGranted,
      MacosPermission.accessibility: MacosPermissionStatus.granted,
    });

    await MacosFirstLaunchPermissions(
      permissions: permissions,
      preferences: SharedPreferences.getInstance(),
      supported: true,
    ).requestIfNeeded();

    expect(permissions.requested, const [
      MacosPermission.automation,
      MacosPermission.homeDirectory,
    ]);
  });

  test('is a no-op outside macOS', () async {
    final preferences = SharedPreferences.getInstance();
    final permissions = _FakeMacosPermissions(const {});

    await MacosFirstLaunchPermissions(
      permissions: permissions,
      preferences: preferences,
      supported: false,
    ).requestIfNeeded();

    expect(permissions.statusCalls, 0);
    expect(permissions.requested, isEmpty);
    expect(
      (await preferences).getBool(kMacosInitialPermissionsRequestedKey),
      isNull,
    );
  });
}

final class _FakeMacosPermissions implements MacosPermissions {
  _FakeMacosPermissions(this.statuses);

  final MacosPermissionStatuses statuses;
  final List<MacosPermission> requested = [];
  int statusCalls = 0;

  @override
  Future<MacosPermissionStatuses> getStatuses() async {
    statusCalls++;
    return Map.of(statuses);
  }

  @override
  Future<void> openSystemSettings(MacosPermission permission) async {}

  @override
  Future<MacosPermissionStatus> request(MacosPermission permission) async {
    requested.add(permission);
    return MacosPermissionStatus.granted;
  }
}
