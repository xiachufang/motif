import 'dart:typed_data';

/// Buffers microphone PCM without discarding bytes at recorder shutdown.
class DoubaoPcmFrameBuffer {
  DoubaoPcmFrameBuffer({required this.frameSize}) {
    if (frameSize <= 0) {
      throw ArgumentError.value(frameSize, 'frameSize', 'must be positive');
    }
  }

  final int frameSize;
  final List<int> _bytes = <int>[];

  bool get isEmpty => _bytes.isEmpty;

  void addAll(List<int> bytes) => _bytes.addAll(bytes);

  void clear() => _bytes.clear();

  /// Removes and returns one complete frame, or null if only a tail remains.
  Uint8List? takeFullFrame() {
    if (_bytes.length < frameSize) return null;
    final frame = Uint8List.fromList(_bytes.sublist(0, frameSize));
    _bytes.removeRange(0, frameSize);
    return frame;
  }

  /// Removes the remaining partial frame and pads it with PCM silence.
  Uint8List? takePaddedRemainder() {
    if (_bytes.isEmpty) return null;
    if (_bytes.length >= frameSize) {
      throw StateError('complete PCM frames must be drained first');
    }
    final frame = Uint8List(frameSize)..setRange(0, _bytes.length, _bytes);
    _bytes.clear();
    return frame;
  }
}

/// Produces the 20 ms media timeline expected by the original Python client.
class DoubaoAudioFrameClock {
  DoubaoAudioFrameClock({required this.frameDurationMs}) {
    if (frameDurationMs <= 0) {
      throw ArgumentError.value(
        frameDurationMs,
        'frameDurationMs',
        'must be positive',
      );
    }
  }

  final int frameDurationMs;
  int? _startTimestampMs;
  int _frameIndex = 0;

  void reset() {
    _startTimestampMs = null;
    _frameIndex = 0;
  }

  int nextTimestampMs(int wallClockNowMs) {
    final startTimestampMs = _startTimestampMs ??= wallClockNowMs;
    final timestampMs = startTimestampMs + _frameIndex * frameDurationMs;
    _frameIndex += 1;
    return timestampMs;
  }
}
