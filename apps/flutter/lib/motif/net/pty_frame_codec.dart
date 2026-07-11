import 'dart:typed_data';

import 'package:archive/archive.dart';

const int ptyFrameFlagCompressed = 0x01;
const int ptyFrameFlagReserved = 0xfe;

class PtyFrameDecodeException implements Exception {
  final String message;
  const PtyFrameDecodeException(this.message);

  @override
  String toString() => 'pty frame decode: $message';
}

Uint8List decodePtyPayload(Uint8List payload) {
  if (payload.isEmpty) {
    throw const PtyFrameDecodeException('empty framed payload');
  }
  final flags = payload[0];
  if ((flags & ptyFrameFlagReserved) != 0) {
    throw PtyFrameDecodeException(
      'reserved flags set: 0x${flags.toRadixString(16).padLeft(2, '0')}',
    );
  }
  final body = payload.sublist(1);
  if ((flags & ptyFrameFlagCompressed) == 0) return body;
  try {
    return Uint8List.fromList(const ZLibDecoder().decodeBytes(body));
  } catch (e) {
    throw PtyFrameDecodeException('zlib decode failed: $e');
  }
}
