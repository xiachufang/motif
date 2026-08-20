import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/doubao_asr/doubao_audio_frames.dart';

void main() {
  group('DoubaoPcmFrameBuffer', () {
    test('drains every complete frame and preserves the padded tail', () {
      final buffer = DoubaoPcmFrameBuffer(frameSize: 4)
        ..addAll(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));

      expect(buffer.takeFullFrame(), Uint8List.fromList([1, 2, 3, 4]));
      expect(buffer.takeFullFrame(), Uint8List.fromList([5, 6, 7, 8]));
      expect(buffer.takeFullFrame(), isNull);
      expect(buffer.takePaddedRemainder(), Uint8List.fromList([9, 10, 0, 0]));
      expect(buffer.isEmpty, isTrue);
    });

    test('keeps frames intact when microphone chunks split their bytes', () {
      final buffer = DoubaoPcmFrameBuffer(frameSize: 4)
        ..addAll(Uint8List.fromList([1, 2]));

      expect(buffer.takeFullFrame(), isNull);
      buffer.addAll(Uint8List.fromList([3, 4, 5]));
      expect(buffer.takeFullFrame(), Uint8List.fromList([1, 2, 3, 4]));
      expect(buffer.takePaddedRemainder(), Uint8List.fromList([5, 0, 0, 0]));
    });
  });

  group('DoubaoAudioFrameClock', () {
    test('uses a fixed start and advances exactly one frame at a time', () {
      final clock = DoubaoAudioFrameClock(frameDurationMs: 20);

      expect(clock.nextTimestampMs(1000), 1000);
      expect(clock.nextTimestampMs(5000), 1020);
      expect(clock.nextTimestampMs(9000), 1040);
    });

    test('starts a new media timeline after reset', () {
      final clock = DoubaoAudioFrameClock(frameDurationMs: 20);

      expect(clock.nextTimestampMs(1000), 1000);
      clock.reset();
      expect(clock.nextTimestampMs(7000), 7000);
    });
  });
}
