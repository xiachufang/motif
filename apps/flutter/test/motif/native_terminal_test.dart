@Tags(['native'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:motif/motif/terminal/ghostty_bindings.g.dart';
import 'package:motif/motif/terminal/key_map.dart';
import 'package:motif/motif/terminal/terminal_key.dart';
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

  test('OSC 8 metadata survives into snapshots and URI lookup', () {
    const uri = 'https://example.com/docs?q=osc8';
    final ts = TerminalState(onHostWrite: (_) {});
    ts.init(20, 3);

    ts.feedBytes(
      Uint8List.fromList(utf8.encode('\x1b]8;;$uri\x07open\x1b]8;;\x07 plain')),
    );
    ts.updateRenderState();

    final snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(
      snapshot.hasHyperlinkAt(const TerminalCellPoint(row: 0, col: 0)),
      isTrue,
    );
    expect(
      snapshot.hasHyperlinkAt(const TerminalCellPoint(row: 0, col: 4)),
      isFalse,
    );
    expect(snapshot.lines.first.cells[3].hyperlinkUri, uri);
    expect(ts.hyperlinkUriAt(const TerminalCellPoint(row: 0, col: 3)), uri);
    expect(ts.hyperlinkUriAt(const TerminalCellPoint(row: 0, col: 4)), isNull);

    ts.dispose();
  });

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

  test('semantic key catalog matches the generated Ghostty C enum', () {
    for (final key in terminalKeySpecs) {
      expect(
        mapFlutterKey(key.logicalKey)?.value,
        key.ghosttyKey,
        reason: '${key.id} has a stale Ghostty key value',
      );
    }
  });

  test('cursor keys follow normal and application terminal modes', () {
    final out = <int>[];
    final ts = TerminalState(onHostWrite: (bytes) => out.addAll(bytes));
    ts.init(80, 24);

    ts.encodeKeyAndWrite(
      GhosttyKey.GHOSTTY_KEY_ARROW_UP,
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
      0,
      null,
    );
    expect(out, [0x1b, 0x5b, 0x41]);

    out.clear();
    ts.feedBytes(Uint8List.fromList(const [0x1b, 0x5b, 0x3f, 0x31, 0x68]));
    ts.encodeKeyAndWrite(
      GhosttyKey.GHOSTTY_KEY_ARROW_UP,
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
      0,
      null,
    );
    expect(out, [0x1b, 0x4f, 0x41]);

    ts.dispose();
  });

  test('backspace follows DEC backarrow-key mode', () {
    final out = <int>[];
    final ts = TerminalState(onHostWrite: (bytes) => out.addAll(bytes));
    ts.init(80, 24);

    ts.encodeKeyAndWrite(
      GhosttyKey.GHOSTTY_KEY_BACKSPACE,
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
      0,
      null,
    );
    expect(out, [0x7f]);

    out.clear();
    ts.feedBytes(
      Uint8List.fromList(const [0x1b, 0x5b, 0x3f, 0x36, 0x37, 0x68]),
    );
    ts.encodeKeyAndWrite(
      GhosttyKey.GHOSTTY_KEY_BACKSPACE,
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
      0,
      null,
    );
    expect(out, [0x08]);

    ts.dispose();
  });

  test('paste encoding follows mode 2004 and sanitizes control bytes', () {
    final out = <int>[];
    final ts = TerminalState(onHostWrite: (bytes) => out.addAll(bytes));
    ts.init(80, 24);

    ts.encodePasteAndWrite(Uint8List.fromList(utf8.encode('a\nb')));
    expect(out, utf8.encode('a\rb'));

    out.clear();
    ts.feedBytes(
      Uint8List.fromList(const [
        0x1b,
        0x5b,
        0x3f,
        0x32,
        0x30,
        0x30,
        0x34,
        0x68,
      ]),
    );
    ts.encodePasteAndWrite(
      Uint8List.fromList([...utf8.encode('a'), 0x1b, ...utf8.encode('b')]),
    );
    expect(out, [
      0x1b,
      0x5b,
      0x32,
      0x30,
      0x30,
      0x7e,
      ...utf8.encode('a b'),
      0x1b,
      0x5b,
      0x32,
      0x30,
      0x31,
      0x7e,
    ]);

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

  test('Ghostty key events encode semantic Ctrl+C', () {
    final out = <int>[];
    final ts = TerminalState(onHostWrite: (bytes) => out.addAll(bytes));
    ts.init(80, 24);

    ts.encodeKeyAndWrite(
      GhosttyKey.GHOSTTY_KEY_C,
      GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
      1 << 1,
      'c',
      unshiftedCodepoint: 'c'.codeUnitAt(0),
    );

    expect(out, [0x03]);
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

  test('snapshot cursor spans both columns of a wide character', () {
    final ts = TerminalState(onHostWrite: (_) {});
    ts.init(8, 2);
    ts.feedBytes(Uint8List.fromList(utf8.encode('好')));
    ts.updateRenderState();

    var snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.lines.first.cells.single.widthCells, 2);
    expect(snapshot.cursorCellSpan, (col: 2, widthCells: 1));

    // Move left onto the wide character's spacer tail. The visual cursor must
    // move to the lead cell and cover the complete grapheme.
    ts.feedBytes(Uint8List.fromList([0x1b, 0x5b, 0x44]));
    ts.updateRenderState();
    snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.cursorX, 1);
    expect(snapshot.cursorCellSpan, (col: 0, widthCells: 2));

    ts.dispose();
  });

  test('scrollbar metrics support absolute scrollback positioning', () {
    final ts = TerminalState(onHostWrite: (_) {});
    ts.init(12, 3);
    ts.feedBytes(
      Uint8List.fromList(
        utf8.encode(List.generate(12, (i) => 'line$i').join('\r\n')),
      ),
    );
    ts.updateRenderState();

    var snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.hasScrollback, isTrue);
    expect(snapshot.scrollViewportRows, 3);
    expect(snapshot.scrollTotalRows, greaterThan(snapshot.scrollViewportRows));
    expect(snapshot.viewportOffset, snapshot.maxViewportOffset);

    ts.scrollToOffset(0);
    ts.updateRenderState();
    snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.viewportOffset, 0);

    ts.scrollToOffset(snapshot.maxViewportOffset);
    ts.updateRenderState();
    snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.viewportOffset, snapshot.maxViewportOffset);

    ts.dispose();
  });

  test('new output follows the bottom but preserves a scrolled viewport', () {
    final ts = TerminalState(onHostWrite: (_) {});
    ts.init(16, 3);
    ts.feedBytes(
      Uint8List.fromList(
        utf8.encode(List.generate(10, (i) => 'line$i\r\n').join()),
      ),
    );
    ts.updateRenderState();

    var snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.viewportOffset, snapshot.maxViewportOffset);
    final previousBottom = snapshot.maxViewportOffset;

    ts.feedBytes(Uint8List.fromList(utf8.encode('bottom output\r\n')));
    ts.updateRenderState();
    snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.maxViewportOffset, greaterThan(previousBottom));
    expect(snapshot.viewportOffset, snapshot.maxViewportOffset);

    ts.scrollToOffset(2);
    ts.updateRenderState();
    snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.viewportOffset, 2);
    final historyText = snapshot.visibleText;

    ts.feedBytes(Uint8List.fromList(utf8.encode('background output\r\n')));
    ts.updateRenderState();
    snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.viewportOffset, 2);
    expect(snapshot.visibleText, historyText);
    expect(snapshot.isAtLatest, isFalse);

    ts.dispose();
  });

  test('PTY snapshot restore returns a scrolled viewport to latest', () {
    final ts = TerminalState(onHostWrite: (_) {});
    ts.init(18, 3);
    ts.feedBytes(
      Uint8List.fromList(
        utf8.encode(List.generate(12, (i) => 'old$i\r\n').join()),
      ),
    );
    ts.updateRenderState();
    ts.scrollToOffset(2);
    ts.updateRenderState();

    var snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );
    expect(snapshot.isAtLatest, isFalse);

    // This is the clear/reset portion emitted by motifd before the content of
    // a self-contained cold or stale-cursor VT snapshot. Split it inside the
    // 3J sequence because WebSocket/ring delivery boundaries are arbitrary.
    final restoredLines = List.generate(14, (i) => 'restored$i\r\n').join();
    ts.feedBytes(
      Uint8List.fromList(utf8.encode('\x1b[!p\x1b[?1049l\x1b[H\x1b[2J\x1b[3')),
    );
    ts.feedBytes(Uint8List.fromList(utf8.encode('J\x1b[0m$restoredLines')));
    ts.updateRenderState();
    snapshot = ts.snapshot(
      defaultForegroundArgb: 0xffffffff,
      defaultBackgroundArgb: 0xff000000,
    );

    expect(snapshot.hasScrollback, isTrue);
    expect(snapshot.viewportOffset, snapshot.maxViewportOffset);
    expect(snapshot.visibleText, contains('restored13'));

    ts.dispose();
  });

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
