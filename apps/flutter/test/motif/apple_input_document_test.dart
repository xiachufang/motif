import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/apple_input_document.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('motif/ime_document');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('invokes the native document channel on iOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    await AppleInputDocument.activate('tab-1', defaultEnglish: true);
    await AppleInputDocument.dispose('tab-1');

    expect(calls, hasLength(2));
    expect(calls[0].method, 'activateDocument');
    expect(calls[0].arguments, {'id': 'tab-1', 'defaultEnglish': true});
    expect(calls[1].method, 'disposeDocument');
    expect(calls[1].arguments, {'id': 'tab-1'});
  });

  test('invokes the native document channel on macOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    await AppleInputDocument.activate('tab-2', defaultEnglish: false);

    expect(calls.single.method, 'activateDocument');
    expect(calls.single.arguments, {'id': 'tab-2', 'defaultEnglish': false});
  });

  test(
    'does not invoke the native document channel on other platforms',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await AppleInputDocument.activate('tab-1', defaultEnglish: true);
      await AppleInputDocument.dispose('tab-1');

      expect(calls, isEmpty);
    },
  );

  test('does not invoke the native document channel for empty ids', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    await AppleInputDocument.activate('', defaultEnglish: true);
    await AppleInputDocument.dispose('');

    expect(calls, isEmpty);
  });
}
