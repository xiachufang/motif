import 'dart:convert';
import 'dart:typed_data';

/// Wrap clipboard text in xterm bracketed-paste markers before sending it to a
/// shell. This keeps pasted newlines as paste data instead of typed commands.
Uint8List bracketedPasteBytes(String text) => Uint8List.fromList([
  0x1b,
  0x5b,
  0x32,
  0x30,
  0x30,
  0x7e,
  ...utf8.encode(text),
  0x1b,
  0x5b,
  0x32,
  0x30,
  0x31,
  0x7e,
]);
