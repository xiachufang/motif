import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/pty_output_hub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PtyOutputHub', () {
    late PtyOutputHub hub;

    setUp(() {
      hub = PtyOutputHub();
    });

    tearDown(() {
      hub.dispose();
    });

    test('delivers live output to registered sink', () {
      final received = <Uint8List>[];
      hub.registerSink('pty-1', received.add);

      hub.handleOutput('pty-1', Uint8List.fromList([1, 2, 3]));

      expect(received, hasLength(1));
      expect(received.single, Uint8List.fromList([1, 2, 3]));
    });

    test('replays buffered bytes to a late subscriber', () async {
      hub.handleOutput('pty-1', Uint8List.fromList([10, 20]));
      hub.handleOutput('pty-1', Uint8List.fromList([30]));

      final received = <int>[];
      hub.registerSink('pty-1', (bytes) => received.addAll(bytes));

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(received, [10, 20, 30]);
    });

    test('clearPty drops replay for that pty only', () async {
      hub.handleOutput('a', Uint8List.fromList([1]));
      hub.handleOutput('b', Uint8List.fromList([2]));
      hub.clearPty('a');

      final a = <int>[];
      final b = <int>[];
      hub.registerSink('a', (bytes) => a.addAll(bytes));
      hub.registerSink('b', (bytes) => b.addAll(bytes));

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(a, isEmpty);
      expect(b, [2]);
    });

    test('clearAll drops sinks and replay', () async {
      final received = <Uint8List>[];
      hub.registerSink('pty-1', received.add);
      hub.handleOutput('pty-1', Uint8List.fromList([9]));
      expect(received, hasLength(1));

      hub.clearAll();
      hub.handleOutput('pty-1', Uint8List.fromList([8]));
      expect(received, hasLength(1));
    });

    test('unregisterSink stops delivery', () {
      final received = <Uint8List>[];
      void sink(Uint8List bytes) => received.add(bytes);
      hub.registerSink('pty-1', sink);
      hub.unregisterSink('pty-1', sink);
      hub.handleOutput('pty-1', Uint8List.fromList([1]));
      expect(received, isEmpty);
    });

    test('bytesFromPtyOutput decodes data_bytes and data_b64', () {
      final raw = PtyOutputHub.bytesFromPtyOutput({
        'data_bytes': Uint8List.fromList([7, 8]),
      });
      expect(raw, Uint8List.fromList([7, 8]));

      final b64 = PtyOutputHub.bytesFromPtyOutput({'data_b64': 'AQI='});
      expect(b64, Uint8List.fromList([1, 2]));

      expect(PtyOutputHub.bytesFromPtyOutput({}), isNull);
    });
  });
}
