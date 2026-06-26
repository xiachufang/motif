import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/pty_frame_codec.dart';

void main() {
  group('PTY frame codec', () {
    test('legacy mode returns payload unchanged', () {
      final payload = Uint8List.fromList('abc'.codeUnits);
      expect(decodePtyPayload(payload, framedZlib: false), payload);
    });

    test('framed mode decodes raw payload after marker', () {
      final frame = Uint8List.fromList([0, ...'abc'.codeUnits]);
      expect(decodePtyPayload(frame, framedZlib: true), 'abc'.codeUnits);
    });

    test('framed mode decodes zlib payload', () {
      final compressed = const ZLibEncoder().encode('abcabcabc'.codeUnits);
      final frame = Uint8List.fromList([ptyFrameFlagCompressed, ...compressed]);
      expect(decodePtyPayload(frame, framedZlib: true), 'abcabcabc'.codeUnits);
    });

    test('framed mode rejects malformed frames', () {
      expect(
        () => decodePtyPayload(Uint8List(0), framedZlib: true),
        throwsA(isA<PtyFrameDecodeException>()),
      );
      expect(
        () => decodePtyPayload(Uint8List.fromList([0x02]), framedZlib: true),
        throwsA(isA<PtyFrameDecodeException>()),
      );
      expect(
        () => decodePtyPayload(
          Uint8List.fromList([ptyFrameFlagCompressed, 1, 2, 3]),
          framedZlib: true,
        ),
        throwsA(isA<PtyFrameDecodeException>()),
      );
    });
  });
}
