@Tags(['native'])
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:motif/motif/terminal/ghostty_bindings.g.dart';
import 'package:motif/motif/terminal/key_map.dart';
import 'package:motif/motif/terminal/terminal_snapshot.dart';
import 'package:motif/motif/terminal/terminal_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the libghostty engine in *network mode* — the path Motif uses to
/// render remote PTY output. Requires the native libghostty asset (Zig on
/// PATH). Run: flutter test test/motif/native_terminal_test.dart
///
/// This is the core validation of the migration: bytes fed from the "network"
/// via [TerminalState.feedBytes] must land in the render grid, and encoded
/// keystrokes must flow out through [TerminalState.onHostWrite] (the WebSocket
/// sink in the real app) instead of a local PTY.
void main() {
  test(
    'feedBytes renders text into the grid; no local PTY in network mode',
    () {
      final out = <int>[];
      final ts = TerminalState(onHostWrite: (b) => out.addAll(b));
      ts.init(80, 24);

      ts.feedBytes(Uint8List.fromList('hello world'.codeUnits));
      ts.updateRenderState();

      // Walk the render grid and collect the text of the first non-empty row.
      final firstRow = _firstRowText(ts);
      expect(firstRow.trim(), startsWith('hello world'));

      ts.dispose();
    },
  );

  test('encoded keystrokes are routed to onHostWrite (the network sink)', () {
    final out = <int>[];
    final ts = TerminalState(onHostWrite: (b) => out.addAll(b));
    ts.init(80, 24);

    // Type 'a' — the key encoder should emit the byte to the host sink.
    ts.writeToPty(Uint8List.fromList('a'.codeUnits));
    expect(out, contains('a'.codeUnitAt(0)));

    ts.dispose();
  });

  test('left and right arrows map and encode to terminal bytes', () {
    final out = <int>[];
    final ts = TerminalState(onHostWrite: (b) => out.addAll(b));
    ts.init(80, 24);

    expect(
      mapFlutterKey(LogicalKeyboardKey.arrowLeft),
      GhosttyKey.GHOSTTY_KEY_ARROW_LEFT,
    );
    expect(
      mapFlutterKey(LogicalKeyboardKey.arrowRight),
      GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT,
    );

    ts.encodeKeyAndWrite(
      GhosttyKey.GHOSTTY_KEY_ARROW_LEFT,
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
      0,
      null,
    );
    expect(out, [0x1b, 0x5b, 0x44]);

    out.clear();
    ts.encodeKeyAndWrite(
      GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT,
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
      0,
      null,
    );
    expect(out, [0x1b, 0x5b, 0x43]);

    ts.dispose();
  });

  test('shifted semicolon encodes colon', () {
    final out = <int>[];
    final ts = TerminalState(onHostWrite: (b) => out.addAll(b));
    ts.init(80, 24);

    expect(logicalKeyCharacter(LogicalKeyboardKey.semicolon, shift: true), ':');
    expect(
      logicalKeyUnshiftedCodepoint(LogicalKeyboardKey.semicolon),
      ';'.codeUnitAt(0),
    );
    ts.encodeKeyAndWrite(
      GhosttyKey.GHOSTTY_KEY_SEMICOLON,
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
      1,
      logicalKeyCharacter(LogicalKeyboardKey.semicolon, shift: true),
      unshiftedCodepoint: logicalKeyUnshiftedCodepoint(
        LogicalKeyboardKey.semicolon,
      ),
    );
    expect(out, ':'.codeUnits);

    ts.dispose();
  });

  test('ctrl+a encodes control code', () {
    final out = <int>[];
    final ts = TerminalState(onHostWrite: (b) => out.addAll(b));
    ts.init(80, 24);

    expect(logicalKeyControlCode(LogicalKeyboardKey.keyA, shift: false), 0x01);
    expect(logicalKeyControlCode(LogicalKeyboardKey.keyB, shift: false), 0x02);
    expect(logicalKeyControlCode(LogicalKeyboardKey.keyC, shift: false), 0x03);
    ts.writeToPty(
      Uint8List.fromList([
        logicalKeyControlCode(LogicalKeyboardKey.keyA, shift: false)!,
      ]),
    );
    expect(out, [0x01]);

    ts.dispose();
  });

  test('CRLF advances to a new row', () {
    final ts = TerminalState(onHostWrite: (_) {});
    ts.init(80, 24);
    ts.feedBytes(Uint8List.fromList('line1\r\nline2'.codeUnits));
    ts.updateRenderState();

    final rows = _allRowsText(ts);
    expect(rows.any((r) => r.trim() == 'line1'), isTrue, reason: 'rows=$rows');
    expect(
      rows.any((r) => r.trim().startsWith('line2')),
      isTrue,
      reason: 'rows=$rows',
    );

    ts.dispose();
  });

  test(
    'cursor-only movement updates cursor metadata without changing text',
    () {
      final ts = TerminalState(onHostWrite: (_) {});
      ts.init(80, 24);

      ts.feedBytes(Uint8List.fromList('abc'.codeUnits));
      ts.updateRenderState();
      expect(ts.cursorX, 3);
      expect(_firstRowText(ts).trim(), startsWith('abc'));

      ts.setDirty(GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE);
      ts.feedBytes(Uint8List.fromList([0x1b, 0x5b, 0x44]));
      ts.updateRenderState();

      expect(
        ts.getDirty(),
        GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE,
        reason: 'cursor-only moves may not mark render rows dirty',
      );
      expect(ts.cursorX, 2);
      expect(_firstRowText(ts).trim(), startsWith('abc'));

      ts.dispose();
    },
  );

  test('tracked selection keeps pointing at text after scrollback changes', () {
    final ts = TerminalState(onHostWrite: (_) {});
    ts.init(20, 3);
    ts.feedBytes(Uint8List.fromList('alpha beta'.codeUnits));

    expect(
      ts.beginTrackedSelection(const TerminalCellPoint(row: 0, col: 0)),
      isTrue,
    );
    expect(
      ts.updateTrackedSelectionEnd(const TerminalCellPoint(row: 0, col: 4)),
      isTrue,
    );
    expect(ts.formatTrackedSelection(), 'alpha');

    ts.feedBytes(
      Uint8List.fromList('\r\none\r\ntwo\r\nthree\r\nfour'.codeUnits),
    );

    expect(ts.formatTrackedSelection(), 'alpha');

    ts.dispose();
  });
}

String _firstRowText(TerminalState ts) {
  for (final r in _allRowsText(ts)) {
    if (r.trim().isNotEmpty) return r;
  }
  return '';
}

List<String> _allRowsText(TerminalState ts) {
  final rows = <String>[];
  ts.populateRowIterator();
  while (ts.rowIteratorNext()) {
    final sb = StringBuffer();
    ts.populateRowCells();
    while (ts.rowCellsNext()) {
      final len = ts.getCellGraphemeLen();
      sb.write(ts.getCellGrapheme(len));
    }
    rows.add(sb.toString());
  }
  return rows;
}
