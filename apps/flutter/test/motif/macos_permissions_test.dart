import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/macos_permissions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('motif/macos_permissions-test');
  const permissions = MethodChannelMacosPermissions(
    channel: channel,
    supported: true,
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'maps native statuses and treats unknown values as unavailable',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getStatuses');
            return <String, String>{
              'fullDiskAccess': 'managedExternally',
              'screenRecording': 'granted',
              'accessibility': 'futureStatus',
            };
          });

      final statuses = await permissions.getStatuses();

      expect(
        statuses[MacosPermission.fullDiskAccess],
        MacosPermissionStatus.managedExternally,
      );
      expect(
        statuses[MacosPermission.screenRecording],
        MacosPermissionStatus.granted,
      );
      expect(
        statuses[MacosPermission.accessibility],
        MacosPermissionStatus.unavailable,
      );
      expect(
        statuses[MacosPermission.automation],
        MacosPermissionStatus.unavailable,
      );
    },
  );

  test(
    'sends stable permission identifiers for request and settings',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'request' ? 'notGranted' : null;
          });

      final status = await permissions.request(MacosPermission.screenRecording);
      await permissions.openSystemSettings(MacosPermission.fullDiskAccess);

      expect(status, MacosPermissionStatus.notGranted);
      expect(calls, hasLength(2));
      expect(calls[0].method, 'request');
      expect(calls[0].arguments, {'permission': 'screenRecording'});
      expect(calls[1].method, 'openSystemSettings');
      expect(calls[1].arguments, {'permission': 'fullDiskAccess'});
    },
  );

  test('is a safe no-op on unsupported platforms', () async {
    const unsupported = MethodChannelMacosPermissions(
      channel: channel,
      supported: false,
    );

    final statuses = await unsupported.getStatuses();
    final requested = await unsupported.request(
      MacosPermission.screenRecording,
    );
    await unsupported.openSystemSettings(MacosPermission.fullDiskAccess);

    expect(statuses.values, everyElement(MacosPermissionStatus.unavailable));
    expect(requested, MacosPermissionStatus.unavailable);
  });
}
