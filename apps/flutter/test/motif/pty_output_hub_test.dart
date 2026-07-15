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

    test('reports PTYs with mounted terminal sinks', () {
      void sink(Uint8List _) {}

      hub.registerSink('pty-1', sink);
      hub.registerSink('pty-2', sink);
      expect(hub.sinkPtyIds, {'pty-1', 'pty-2'});

      hub.unregisterSink('pty-1', sink);
      expect(hub.sinkPtyIds, {'pty-2'});
    });

    test('replays buffered bytes to a late subscriber', () async {
      hub.handleOutput('pty-1', Uint8List.fromList([10, 20]));
      hub.handleOutput('pty-1', Uint8List.fromList([30]));

      final received = <int>[];
      hub.registerSink('pty-1', (bytes) => received.addAll(bytes));

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(received, [10, 20, 30]);
    });

    test(
      'replay ring retains the exact byte tail across segment wraps',
      () async {
        final smallHub = PtyOutputHub(
          replayCapacityBytes: 8,
          replayBytesPerTick: 4,
          replayInterval: Duration.zero,
        );
        addTearDown(smallHub.dispose);

        smallHub.handleOutput('pty-1', Uint8List.fromList([0, 1, 2]));
        smallHub.handleOutput('pty-1', Uint8List.fromList([3, 4, 5, 6]));
        smallHub.handleOutput('pty-1', Uint8List.fromList([7, 8, 9]));

        expect(smallHub.replayBytesFor('pty-1'), 8);
        final received = <int>[];
        smallHub.registerSink('pty-1', received.addAll);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(received, [2, 3, 4, 5, 6, 7, 8, 9]);
      },
    );

    test('a write larger than the ring retains only its tail', () async {
      final smallHub = PtyOutputHub(
        replayCapacityBytes: 8,
        replayBytesPerTick: 4,
        replayInterval: Duration.zero,
      );
      addTearDown(smallHub.dispose);

      smallHub.handleOutput(
        'pty-1',
        Uint8List.fromList(List<int>.generate(12, (index) => index)),
      );

      final received = <int>[];
      smallHub.registerSink('pty-1', received.addAll);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(smallHub.replayBytesFor('pty-1'), 8);
      expect(received, [4, 5, 6, 7, 8, 9, 10, 11]);
    });

    test(
      'live output stays ordered when the ring wraps during replay',
      () async {
        final smallHub = PtyOutputHub(
          replayCapacityBytes: 8,
          replayBytesPerTick: 2,
          replayInterval: const Duration(milliseconds: 5),
        );
        addTearDown(smallHub.dispose);

        smallHub.handleOutput(
          'pty-1',
          Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        );
        final received = <int>[];
        smallHub.registerSink('pty-1', received.addAll);
        // This replaces the live ring completely. The already-started replay
        // must keep its views of the evicted segments alive, then append the
        // new live bytes behind them in stream order.
        smallHub.handleOutput(
          'pty-1',
          Uint8List.fromList([9, 10, 11, 12, 13, 14, 15, 16]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(received, List<int>.generate(16, (index) => index + 1));
      },
    );

    test('caps live output queued behind a slow replay', () async {
      final smallHub = PtyOutputHub(
        replayCapacityBytes: 8,
        replayBytesPerTick: 1,
        replayInterval: const Duration(milliseconds: 50),
        maxReplayBacklogBytes: 10,
      );
      addTearDown(smallHub.dispose);

      smallHub.handleOutput(
        'pty-1',
        Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      );
      final received = <int>[];
      final overflows = <int>[];
      smallHub.onReplayOverflow = (_, pendingBytes) {
        overflows.add(pendingBytes);
      };
      smallHub.registerSink('pty-1', received.addAll);

      // The 8-byte replay plus these 3 live bytes exceeds the 10-byte cap.
      // The partial delivery is abandoned and the owner is asked to obtain a
      // self-contained snapshot instead of silently dropping bytes.
      smallHub.handleOutput('pty-1', Uint8List.fromList([9, 10, 11]));

      expect(overflows, [11]);
      expect(smallHub.replayBacklogBytesFor('pty-1'), 0);
      expect(smallHub.replayBytesFor('pty-1'), 0);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(received, isEmpty);

      // Output arriving after the overflow is live again while the owner
      // performs its cold reconnect.
      smallHub.handleOutput('pty-1', Uint8List.fromList([12]));
      expect(received, [12]);
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
