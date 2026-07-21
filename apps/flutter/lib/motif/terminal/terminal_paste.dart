import 'dart:convert';
import 'dart:typed_data';

/// Wrap raw input in xterm bracketed-paste markers.
Uint8List bracketedPastePayloadBytes(Iterable<int> payload) =>
    Uint8List.fromList([
      0x1b,
      0x5b,
      0x32,
      0x30,
      0x30,
      0x7e,
      ...payload,
      0x1b,
      0x5b,
      0x32,
      0x30,
      0x31,
      0x7e,
    ]);

/// Wrap clipboard text in xterm bracketed-paste markers before sending it to a
/// shell. This keeps pasted newlines as paste data instead of typed commands.
Uint8List bracketedPasteBytes(String text) =>
    bracketedPastePayloadBytes(utf8.encode(text));
