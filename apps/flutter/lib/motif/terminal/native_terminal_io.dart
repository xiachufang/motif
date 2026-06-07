import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../state/motif_client.dart';
import 'motif_terminal_view.dart';
import 'terminal_palette.dart';

/// Native: the real libghostty-backed terminal surface.
Widget nativeTerminalView({
  Key? key,
  required MotifClient motif,
  required String ptyId,
  required double fontSize,
  required bool active,
  required int focusSerial,
  required TerminalPalette palette,
  required ValueListenable<double> keyboardInset,
}) => MotifTerminalView(
  key: key ?? ValueKey('native-$ptyId'),
  motif: motif,
  ptyId: ptyId,
  fontSize: fontSize,
  active: active,
  focusSerial: focusSerial,
  palette: palette,
  keyboardInset: keyboardInset,
);
