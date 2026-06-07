import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../state/motif_client.dart';
import 'terminal_palette.dart';
import 'wasm_terminal_web.dart';

/// Web: use the libghostty-vt WebAssembly terminal (via the GhosttyVt JS
/// bridge). If the bridge is unavailable, the pane renders an explicit error.
/// `dart:ffi` is never imported on web.
Widget nativeTerminalView({
  Key? key,
  required MotifClient motif,
  required String ptyId,
  required double fontSize,
  required bool active,
  required int focusSerial,
  required TerminalPalette palette,
  required ValueListenable<double> keyboardInset,
}) => KeyedSubtree(
  key: key,
  child: buildWebTerminal(
    motif: motif,
    ptyId: ptyId,
    fontSize: fontSize,
    active: active,
    focusSerial: focusSerial,
    palette: palette,
  ),
);
