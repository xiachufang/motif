import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_byte_batcher.dart';

void main() {
  test('coalesces small chunks without changing byte order', () {
    final batcher = TerminalByteBatcher(maxBatchBytes: 6)
      ..add(Uint8List.fromList([1, 2]))
      ..add(Uint8List.fromList([3]))
      ..add(Uint8List.fromList([4, 5, 6]))
      ..add(Uint8List.fromList([7, 8]));

    expect(batcher.pendingBytes, 8);
    expect(batcher.pendingChunks, 4);
    expect(batcher.drain(), [
      [1, 2, 3, 4, 5, 6],
      [7, 8],
    ]);
    expect(batcher.pendingBytes, 0);
    expect(batcher.pendingChunks, 0);
  });

  test('passes large chunks through and clear drops pending data', () {
    final large = Uint8List.fromList([1, 2, 3, 4, 5]);
    final batcher = TerminalByteBatcher(maxBatchBytes: 4)
      ..add(large)
      ..add(Uint8List.fromList([6]));

    final batches = batcher.drain();
    expect(batches, [
      [1, 2, 3, 4, 5],
      [6],
    ]);
    expect(identical(batches.first, large), isFalse);

    batcher.add(Uint8List.fromList([7, 8]));
    batcher.clear();
    expect(batcher.isEmpty, isTrue);
    expect(batcher.pendingBytes, 0);
  });
}
