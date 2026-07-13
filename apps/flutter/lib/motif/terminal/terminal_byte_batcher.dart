import 'dart:collection';
import 'dart:typed_data';

/// Preserves PTY byte order while coalescing small network frames into fewer
/// isolate/FFI calls. Chunks at least [maxBatchBytes] pass through unchanged.
class TerminalByteBatcher {
  TerminalByteBatcher({
    this.maxBatchBytes = 32 * 1024,
    this.maxPendingBytes = 4 * 1024 * 1024,
  }) : assert(maxBatchBytes > 0),
       assert(maxPendingBytes >= maxBatchBytes);

  final int maxBatchBytes;
  final int maxPendingBytes;
  final Queue<Uint8List> _chunks = Queue<Uint8List>();

  int pendingBytes = 0;
  int get pendingChunks => _chunks.length;
  bool get isEmpty => _chunks.isEmpty;

  bool add(Uint8List bytes) {
    if (bytes.isEmpty) return true;
    if (pendingBytes + bytes.length > maxPendingBytes) return false;
    final owned = Uint8List.fromList(bytes);
    _chunks.addLast(owned);
    pendingBytes += owned.length;
    return true;
  }

  List<Uint8List> drain() {
    final batches = <Uint8List>[];
    while (_chunks.isNotEmpty) {
      final first = _removeFirst();
      if (first.length >= maxBatchBytes || _chunks.isEmpty) {
        batches.add(first);
        continue;
      }

      final parts = <Uint8List>[first];
      var length = first.length;
      while (_chunks.isNotEmpty) {
        final next = _chunks.first;
        if (next.length >= maxBatchBytes ||
            length + next.length > maxBatchBytes) {
          break;
        }
        parts.add(_removeFirst());
        length += next.length;
      }
      if (parts.length == 1) {
        batches.add(first);
      } else {
        final merged = Uint8List(length);
        var offset = 0;
        for (final part in parts) {
          merged.setRange(offset, offset + part.length, part);
          offset += part.length;
        }
        batches.add(merged);
      }
    }
    return batches;
  }

  void clear() {
    _chunks.clear();
    pendingBytes = 0;
  }

  Uint8List _removeFirst() {
    final bytes = _chunks.removeFirst();
    pendingBytes -= bytes.length;
    return bytes;
  }
}
