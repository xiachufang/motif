import 'dart:convert';
import 'dart:typed_data';

class TerminalSnapshot {
  final int frameId;
  final int cols;
  final int rows;
  final int viewportOffset;
  final int scrollTotalRows;
  final int scrollViewportRows;
  final int backgroundArgb;
  final int foregroundArgb;
  final int cursorArgb;
  final bool cursorVisible;
  final bool cursorInViewport;
  final int cursorX;
  final int cursorY;
  final int cursorStyle;
  final bool mouseTrackingActive;
  final bool alternateScreenActive;
  final TerminalSelection? selection;
  final List<TerminalSnapshotRow> lines;

  const TerminalSnapshot({
    this.frameId = 0,
    required this.cols,
    required this.rows,
    this.viewportOffset = 0,
    this.scrollTotalRows = 0,
    this.scrollViewportRows = 0,
    required this.backgroundArgb,
    required this.foregroundArgb,
    required this.cursorArgb,
    required this.cursorVisible,
    required this.cursorInViewport,
    required this.cursorX,
    required this.cursorY,
    required this.cursorStyle,
    required this.mouseTrackingActive,
    required this.alternateScreenActive,
    this.selection,
    required this.lines,
  });

  int get maxViewportOffset {
    final maxOffset = scrollTotalRows - scrollViewportRows;
    return maxOffset > 0 ? maxOffset : 0;
  }

  bool get isAtLatest => viewportOffset >= maxViewportOffset;

  bool get hasScrollback =>
      scrollViewportRows > 0 && scrollTotalRows > scrollViewportRows;

  String get visibleText {
    if (cols <= 0) return '';
    final rows = lines
        .map(
          (line) =>
              line.textForColumns(startCol: 0, endCol: cols - 1).trimRight(),
        )
        .toList();
    while (rows.isNotEmpty && rows.last.isEmpty) {
      rows.removeLast();
    }
    return rows.join('\n');
  }

  /// Whether [point] falls on a cell tagged by Ghostty as an OSC 8 link.
  bool hasHyperlinkAt(TerminalCellPoint point) {
    final viewportRow = point.row - viewportOffset;
    if (viewportRow < 0 || viewportRow >= lines.length || cols <= 0) {
      return false;
    }
    final row = lines[viewportRow];
    final cellIndex = row.cellIndexForColumn(point.col);
    return cellIndex != null && row.cells[cellIndex].hasHyperlink;
  }

  String selectedText(TerminalSelection selection) {
    if (lines.isEmpty || cols <= 0) return '';
    final range = visibleSelection(selection);
    if (range == null) return '';
    final maxRow = lines.length - 1;
    var startRow = _clampInt(range.base.row - viewportOffset, 0, maxRow);
    var endRow = _clampInt(range.extent.row - viewportOffset, 0, maxRow);
    if (endRow < startRow) {
      final tmp = startRow;
      startRow = endRow;
      endRow = tmp;
    }

    final rows = <String>[];
    for (var row = startRow; row <= endRow; row++) {
      final startCol = row == startRow
          ? _clampInt(range.base.col, 0, cols - 1)
          : 0;
      final endCol = row == endRow
          ? _clampInt(range.extent.col, 0, cols - 1)
          : cols - 1;
      rows.add(
        lines[row]
            .textForColumns(startCol: startCol, endCol: endCol)
            .trimRight(),
      );
    }
    return rows.join('\n');
  }

  TerminalSelection? wordSelectionAt(TerminalCellPoint point) {
    final viewportRow = point.row - viewportOffset;
    if (viewportRow < 0 || viewportRow >= lines.length || cols <= 0) {
      return null;
    }
    final row = lines[viewportRow];
    final hitIndex = row.cellIndexForColumn(point.col);
    if (hitIndex == null) return null;
    final hit = row.cells[hitIndex];
    if (!_isSelectableWordCell(hit)) return null;

    var startCol = hit.col;
    var endCol = hit.endCol;

    for (var i = hitIndex - 1; i >= 0; i--) {
      final cell = row.cells[i];
      if (!_isSelectableWordCell(cell) || cell.endCol + 1 != startCol) {
        break;
      }
      startCol = cell.col;
    }

    for (var i = hitIndex + 1; i < row.cells.length; i++) {
      final cell = row.cells[i];
      if (!_isSelectableWordCell(cell) || cell.col != endCol + 1) {
        break;
      }
      endCol = cell.endCol;
    }

    return TerminalSelection(
      base: TerminalCellPoint(
        row: viewportOffset + viewportRow,
        col: _clampInt(startCol, 0, cols - 1),
      ),
      extent: TerminalCellPoint(
        row: viewportOffset + viewportRow,
        col: _clampInt(endCol, 0, cols - 1),
      ),
    );
  }

  TerminalSelection? visibleSelection(TerminalSelection selection) {
    if (lines.isEmpty || cols <= 0) return null;
    final range = selection.normalized;
    final firstVisibleRow = viewportOffset;
    final lastVisibleRow = viewportOffset + lines.length - 1;
    if (range.extent.row < firstVisibleRow || range.base.row > lastVisibleRow) {
      return null;
    }

    final startRow = _clampInt(range.base.row, firstVisibleRow, lastVisibleRow);
    final endRow = _clampInt(range.extent.row, firstVisibleRow, lastVisibleRow);
    return alignSelectionToCellBoundaries(
      TerminalSelection(
        base: TerminalCellPoint(
          row: startRow,
          col: startRow == range.base.row ? range.base.col : 0,
        ),
        extent: TerminalCellPoint(
          row: endRow,
          col: endRow == range.extent.row ? range.extent.col : cols - 1,
        ),
      ),
    );
  }

  /// Expand selection endpoints that land on part of a wide cell so the
  /// visual range always covers the complete grapheme.
  TerminalSelection alignSelectionToCellBoundaries(
    TerminalSelection selection,
  ) {
    final range = selection.normalized;
    return TerminalSelection(
      base: _alignSelectionPoint(range.base, leadingEdge: true),
      extent: _alignSelectionPoint(range.extent, leadingEdge: false),
    );
  }

  /// The grid span occupied by the grapheme under the cursor.
  ///
  /// Ghostty may position the cursor on the spacer tail of a wide character.
  /// In that case the visual cursor starts at the lead cell and spans both
  /// columns.
  ({int col, int widthCells}) get cursorCellSpan {
    final cell = cursorCell;
    if (cell == null) return (col: cursorX, widthCells: 1);
    final widthCells = cell.widthCells <= 0 ? 1 : cell.widthCells;
    return (col: cell.col, widthCells: widthCells);
  }

  /// The rendered cell under the cursor, including the lead cell when the
  /// cursor is positioned on a wide character's spacer tail.
  TerminalSnapshotCell? get cursorCell {
    if (!cursorInViewport || cursorY < 0 || cursorY >= lines.length) {
      return null;
    }
    final row = lines[cursorY];
    final cellIndex = row.cellIndexForColumn(cursorX);
    return cellIndex == null ? null : row.cells[cellIndex];
  }

  TerminalCellPoint _alignSelectionPoint(
    TerminalCellPoint point, {
    required bool leadingEdge,
  }) {
    final viewportRow = point.row - viewportOffset;
    if (viewportRow < 0 || viewportRow >= lines.length) return point;
    final row = lines[viewportRow];
    final cellIndex = row.cellIndexForColumn(point.col);
    if (cellIndex == null) return point;
    final cell = row.cells[cellIndex];
    return TerminalCellPoint(
      row: point.row,
      col: leadingEdge ? cell.col : cell.endCol,
    );
  }
}

class TerminalSnapshotRow {
  final TerminalRowRenderKey renderKey;
  final Uint8List? _encodedCells;
  List<TerminalSnapshotCell>? _cells;

  TerminalSnapshotRow({
    required List<TerminalSnapshotCell> cells,
    TerminalRowRenderKey? renderKey,
  }) : _cells = List<TerminalSnapshotCell>.unmodifiable(cells),
       _encodedCells = null,
       renderKey = renderKey ?? TerminalRowRenderKey.fromCells(cells);

  factory TerminalSnapshotRow.encoded({
    required TerminalRowRenderKey renderKey,
    required Uint8List encodedCells,
  }) = TerminalSnapshotRow._encoded;

  TerminalSnapshotRow._encoded({
    required this.renderKey,
    required this._encodedCells,
  });

  /// Decoding is intentionally deferred until a Picture cache miss or an
  /// interaction (cursor, selection, copy) actually needs cell data.
  List<TerminalSnapshotCell> get cells =>
      _cells ??= _decodeTerminalSnapshotCells(_encodedCells!);

  bool get cellsDecoded => _cells != null;

  int? cellIndexForColumn(int col) {
    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      if (col >= cell.col && col <= cell.endCol) return i;
      if (cell.col > col) break;
    }
    return null;
  }

  String textForColumns({required int startCol, required int endCol}) {
    if (endCol < startCol) return '';
    final out = StringBuffer();
    var cursor = startCol;
    for (final cell in cells) {
      final widthCells = cell.widthCells <= 0 ? 1 : cell.widthCells;
      final cellStart = cell.col;
      final cellEnd = cell.col + widthCells - 1;
      if (cellEnd < startCol) continue;
      if (cellStart > endCol) break;
      if (cellStart > cursor) {
        out.write(' ' * (cellStart - cursor));
      }
      if (!cell.invisible && cell.text.isNotEmpty) {
        out.write(cell.text);
      }
      if (cellEnd + 1 > cursor) {
        cursor = cellEnd + 1;
      }
    }
    return out.toString();
  }
}

class TerminalSnapshotCell {
  final int col;
  final int widthCells;
  final String text;
  final int foregroundArgb;
  final int backgroundArgb;
  final bool drawsBackground;
  final bool bold;
  final bool italic;
  final bool invisible;
  final bool hasHyperlink;

  const TerminalSnapshotCell({
    required this.col,
    required this.widthCells,
    required this.text,
    required this.foregroundArgb,
    required this.backgroundArgb,
    required this.drawsBackground,
    required this.bold,
    required this.italic,
    required this.invisible,
    this.hasHyperlink = false,
  });

  int get endCol => col + (widthCells <= 0 ? 1 : widthCells) - 1;
}

/// A position-independent content key for a rendered terminal row.
///
/// Four independent 32-bit streams keep accidental Picture reuse
/// vanishingly unlikely while remaining cheap to serialize and compare.
class TerminalRowRenderKey {
  final int a;
  final int b;
  final int c;
  final int d;

  const TerminalRowRenderKey(this.a, this.b, this.c, this.d);

  factory TerminalRowRenderKey.fromCells(List<TerminalSnapshotCell> cells) {
    final hasher = TerminalRowRenderKeyHasher();
    for (final cell in cells) {
      hasher.addCell(
        col: cell.col,
        widthCells: cell.widthCells,
        textBytes: utf8.encode(cell.text),
        foregroundArgb: cell.foregroundArgb,
        backgroundArgb: cell.backgroundArgb,
        drawsBackground: cell.drawsBackground,
        bold: cell.bold,
        italic: cell.italic,
        invisible: cell.invisible,
        hasHyperlink: cell.hasHyperlink,
      );
    }
    return hasher.finish(cells.length);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalRowRenderKey &&
          other.a == a &&
          other.b == b &&
          other.c == c &&
          other.d == d;

  @override
  int get hashCode => Object.hash(a, b, c, d);
}

class TerminalRowRenderKeyHasher {
  static const int _mask = 0xffffffff;
  int _a = 0x811c9dc5;
  int _b = 0x9e3779b9;
  int _c = 0x85ebca6b;
  int _d = 0xc2b2ae35;

  void addCell({
    required int col,
    required int widthCells,
    required List<int> textBytes,
    required int foregroundArgb,
    required int backgroundArgb,
    required bool drawsBackground,
    required bool bold,
    required bool italic,
    required bool invisible,
    bool hasHyperlink = false,
  }) {
    addUint32(col);
    addUint32(widthCells);
    addUint32(foregroundArgb);
    addUint32(backgroundArgb);
    addByte(
      (drawsBackground ? 1 : 0) |
          (bold ? 1 << 1 : 0) |
          (italic ? 1 << 2 : 0) |
          (invisible ? 1 << 3 : 0) |
          (hasHyperlink ? 1 << 4 : 0),
    );
    addUint32(textBytes.length);
    for (final byte in textBytes) {
      addByte(byte);
    }
  }

  void addUint32(int value) {
    addByte(value);
    addByte(value >> 8);
    addByte(value >> 16);
    addByte(value >> 24);
  }

  void addByte(int value) {
    final byte = value & 0xff;
    _a = ((_a ^ byte) * 0x01000193) & _mask;
    _b = ((_b + byte) * 0x85ebca77 + 0x27d4eb2d) & _mask;
    _c = ((_c ^ (byte + 0x9e)) * 0xc2b2ae3d) & _mask;
    _d = ((_d + (byte ^ 0xa5)) * 0x165667b1) & _mask;
  }

  TerminalRowRenderKey finish(int cellCount) {
    addUint32(cellCount);
    return TerminalRowRenderKey(_a, _b, _c, _d);
  }
}

class TerminalFrameMetadata {
  final int cols;
  final int rows;
  final int viewportOffset;
  final int scrollTotalRows;
  final int scrollViewportRows;
  final int backgroundArgb;
  final int foregroundArgb;
  final int cursorArgb;
  final bool cursorVisible;
  final bool cursorInViewport;
  final int cursorX;
  final int cursorY;
  final int cursorStyle;
  final bool mouseTrackingActive;
  final bool alternateScreenActive;
  final TerminalSelection? selection;

  const TerminalFrameMetadata({
    required this.cols,
    required this.rows,
    required this.viewportOffset,
    required this.scrollTotalRows,
    required this.scrollViewportRows,
    required this.backgroundArgb,
    required this.foregroundArgb,
    required this.cursorArgb,
    required this.cursorVisible,
    required this.cursorInViewport,
    required this.cursorX,
    required this.cursorY,
    required this.cursorStyle,
    required this.mouseTrackingActive,
    required this.alternateScreenActive,
    this.selection,
  });

  TerminalSnapshot snapshot({
    required int frameId,
    required List<TerminalSnapshotRow> lines,
  }) => TerminalSnapshot(
    frameId: frameId,
    cols: cols,
    rows: rows,
    viewportOffset: viewportOffset,
    scrollTotalRows: scrollTotalRows,
    scrollViewportRows: scrollViewportRows,
    backgroundArgb: backgroundArgb,
    foregroundArgb: foregroundArgb,
    cursorArgb: cursorArgb,
    cursorVisible: cursorVisible,
    cursorInViewport: cursorInViewport,
    cursorX: cursorX,
    cursorY: cursorY,
    cursorStyle: cursorStyle,
    mouseTrackingActive: mouseTrackingActive,
    alternateScreenActive: alternateScreenActive,
    selection: selection,
    lines: lines,
  );
}

class TerminalFrameEncodingResult {
  final Uint8List bytes;
  final int encodedRows;
  final int encodedCells;
  final int viewportOffset;

  const TerminalFrameEncodingResult({
    required this.bytes,
    required this.encodedRows,
    required this.encodedCells,
    required this.viewportOffset,
  });
}

class TerminalFrameEncoder {
  static const int _magic = 0x4d544631;
  static const int _version = 1;
  static const int _flagFull = 1;

  final _TerminalBinaryWriter _writer = _TerminalBinaryWriter();
  late final int _rowCountOffset;
  int _rowCount = 0;
  int _cellCount = 0;
  TerminalEncodedRowWriter? _activeRow;

  TerminalFrameEncoder({
    required int frameId,
    required int baseFrameId,
    required bool full,
    required TerminalFrameMetadata metadata,
  }) {
    _writer
      ..writeUint32(_magic)
      ..writeUint16(_version)
      ..writeUint16(full ? _flagFull : 0)
      ..writeUint64(frameId)
      ..writeUint64(baseFrameId)
      ..writeUint16(metadata.cols)
      ..writeUint16(metadata.rows)
      ..writeUint64(metadata.viewportOffset)
      ..writeUint64(metadata.scrollTotalRows)
      ..writeUint64(metadata.scrollViewportRows)
      ..writeUint32(metadata.backgroundArgb)
      ..writeUint32(metadata.foregroundArgb)
      ..writeUint32(metadata.cursorArgb)
      ..writeUint8(
        (metadata.cursorVisible ? 1 : 0) |
            (metadata.cursorInViewport ? 1 << 1 : 0),
      )
      ..writeInt32(metadata.cursorX)
      ..writeInt32(metadata.cursorY)
      ..writeInt32(metadata.cursorStyle)
      ..writeUint8(
        (metadata.mouseTrackingActive ? 1 : 0) |
            (metadata.alternateScreenActive ? 1 << 1 : 0),
      );
    final selection = metadata.selection;
    _writer.writeUint8(selection == null ? 0 : 1);
    if (selection != null) {
      _writer
        ..writeInt64(selection.base.row)
        ..writeInt32(selection.base.col)
        ..writeInt64(selection.extent.row)
        ..writeInt32(selection.extent.col);
    }
    _rowCountOffset = _writer.length;
    _writer.writeUint16(0);
  }

  TerminalEncodedRowWriter startRow(int rowIndex) {
    if (_activeRow != null) {
      throw StateError('finish the active terminal row before starting one');
    }
    final row = TerminalEncodedRowWriter._(_writer, rowIndex, _finishRow);
    _activeRow = row;
    return row;
  }

  void _finishRow(int cells) {
    _rowCount++;
    _cellCount += cells;
    _activeRow = null;
  }

  TerminalFrameEncodingResult finish(int viewportOffset) {
    if (_activeRow != null) {
      throw StateError('cannot finish a frame with an active terminal row');
    }
    _writer.patchUint16(_rowCountOffset, _rowCount);
    return TerminalFrameEncodingResult(
      bytes: _writer.takeBytes(),
      encodedRows: _rowCount,
      encodedCells: _cellCount,
      viewportOffset: viewportOffset,
    );
  }
}

class TerminalEncodedRowWriter {
  final _TerminalBinaryWriter _writer;
  final void Function(int cells) _onFinish;
  final TerminalRowRenderKeyHasher _hasher = TerminalRowRenderKeyHasher();
  late final int _keyOffset;
  late final int _payloadLengthOffset;
  late final int _payloadStart;
  late final int _cellCountOffset;
  int _cellCount = 0;
  bool _finished = false;

  TerminalEncodedRowWriter._(this._writer, int rowIndex, this._onFinish) {
    _writer.writeUint16(rowIndex);
    _keyOffset = _writer.length;
    for (var i = 0; i < 4; i++) {
      _writer.writeUint32(0);
    }
    _payloadLengthOffset = _writer.length;
    _writer.writeUint32(0);
    _payloadStart = _writer.length;
    _cellCountOffset = _writer.length;
    _writer.writeUint16(0);
  }

  void addCell({
    required int col,
    required int widthCells,
    required List<int> textBytes,
    required int foregroundArgb,
    required int backgroundArgb,
    required bool drawsBackground,
    required bool bold,
    required bool italic,
    required bool invisible,
    bool hasHyperlink = false,
  }) {
    if (_finished) throw StateError('terminal row is already finished');
    if (textBytes.length > 0xffff) {
      throw StateError('terminal grapheme is too large to encode');
    }
    final flags =
        (drawsBackground ? 1 : 0) |
        (bold ? 1 << 1 : 0) |
        (italic ? 1 << 2 : 0) |
        (invisible ? 1 << 3 : 0) |
        (hasHyperlink ? 1 << 4 : 0);
    _writer
      ..writeUint16(col)
      ..writeUint8(widthCells)
      ..writeUint8(flags)
      ..writeUint32(foregroundArgb)
      ..writeUint32(backgroundArgb)
      ..writeUint16(textBytes.length)
      ..writeBytes(textBytes);
    _hasher.addCell(
      col: col,
      widthCells: widthCells,
      textBytes: textBytes,
      foregroundArgb: foregroundArgb,
      backgroundArgb: backgroundArgb,
      drawsBackground: drawsBackground,
      bold: bold,
      italic: italic,
      invisible: invisible,
      hasHyperlink: hasHyperlink,
    );
    _cellCount++;
  }

  TerminalRowRenderKey finish() {
    if (_finished) throw StateError('terminal row is already finished');
    _finished = true;
    final key = _hasher.finish(_cellCount);
    _writer
      ..patchUint32(_keyOffset, key.a)
      ..patchUint32(_keyOffset + 4, key.b)
      ..patchUint32(_keyOffset + 8, key.c)
      ..patchUint32(_keyOffset + 12, key.d)
      ..patchUint32(_payloadLengthOffset, _writer.length - _payloadStart)
      ..patchUint16(_cellCountOffset, _cellCount);
    _onFinish(_cellCount);
    return key;
  }
}

class TerminalFrameUpdate {
  final int frameId;
  final int baseFrameId;
  final bool full;
  final TerminalFrameMetadata metadata;
  final List<TerminalRowPatch> rows;

  const TerminalFrameUpdate({
    required this.frameId,
    required this.baseFrameId,
    required this.full,
    required this.metadata,
    required this.rows,
  });

  factory TerminalFrameUpdate.decode(Uint8List bytes) {
    final reader = _TerminalBinaryReader(bytes);
    if (reader.readUint32() != TerminalFrameEncoder._magic) {
      throw const FormatException('invalid terminal frame magic');
    }
    if (reader.readUint16() != TerminalFrameEncoder._version) {
      throw const FormatException('unsupported terminal frame version');
    }
    final flags = reader.readUint16();
    final frameId = reader.readUint64();
    final baseFrameId = reader.readUint64();
    final cols = reader.readUint16();
    final rowCount = reader.readUint16();
    final viewportOffset = reader.readUint64();
    final scrollTotalRows = reader.readUint64();
    final scrollViewportRows = reader.readUint64();
    final backgroundArgb = reader.readUint32();
    final foregroundArgb = reader.readUint32();
    final cursorArgb = reader.readUint32();
    final cursorFlags = reader.readUint8();
    final cursorX = reader.readInt32();
    final cursorY = reader.readInt32();
    final cursorStyle = reader.readInt32();
    final stateFlags = reader.readUint8();
    final hasSelection = reader.readUint8() != 0;
    final selection = hasSelection
        ? TerminalSelection(
            base: TerminalCellPoint(
              row: reader.readInt64(),
              col: reader.readInt32(),
            ),
            extent: TerminalCellPoint(
              row: reader.readInt64(),
              col: reader.readInt32(),
            ),
          )
        : null;
    final patchCount = reader.readUint16();
    final patches = <TerminalRowPatch>[];
    for (var i = 0; i < patchCount; i++) {
      final rowIndex = reader.readUint16();
      final key = TerminalRowRenderKey(
        reader.readUint32(),
        reader.readUint32(),
        reader.readUint32(),
        reader.readUint32(),
      );
      final payloadLength = reader.readUint32();
      patches.add(
        TerminalRowPatch(
          rowIndex: rowIndex,
          row: TerminalSnapshotRow.encoded(
            renderKey: key,
            encodedCells: reader.readBytesView(payloadLength),
          ),
        ),
      );
    }
    if (!reader.isAtEnd) {
      throw const FormatException('terminal frame has trailing bytes');
    }
    return TerminalFrameUpdate(
      frameId: frameId,
      baseFrameId: baseFrameId,
      full: flags & TerminalFrameEncoder._flagFull != 0,
      metadata: TerminalFrameMetadata(
        cols: cols,
        rows: rowCount,
        viewportOffset: viewportOffset,
        scrollTotalRows: scrollTotalRows,
        scrollViewportRows: scrollViewportRows,
        backgroundArgb: backgroundArgb,
        foregroundArgb: foregroundArgb,
        cursorArgb: cursorArgb,
        cursorVisible: cursorFlags & 1 != 0,
        cursorInViewport: cursorFlags & (1 << 1) != 0,
        cursorX: cursorX,
        cursorY: cursorY,
        cursorStyle: cursorStyle,
        mouseTrackingActive: stateFlags & 1 != 0,
        alternateScreenActive: stateFlags & (1 << 1) != 0,
        selection: selection,
      ),
      rows: patches,
    );
  }

  TerminalSnapshot applyTo(TerminalSnapshot? previous) {
    late final List<TerminalSnapshotRow> lines;
    if (full) {
      if (baseFrameId != 0) {
        throw const FormatException('full terminal frame has a base frame');
      }
      final next = List<TerminalSnapshotRow?>.filled(metadata.rows, null);
      for (final patch in rows) {
        if (patch.rowIndex < 0 || patch.rowIndex >= next.length) {
          throw const FormatException('terminal row index is out of range');
        }
        next[patch.rowIndex] = patch.row;
      }
      if (next.any((row) => row == null)) {
        throw const FormatException('full terminal frame is missing rows');
      }
      lines = [for (final row in next) row!];
    } else {
      if (previous == null || previous.frameId != baseFrameId) {
        throw const FormatException('terminal delta base frame mismatch');
      }
      if (previous.lines.length != metadata.rows ||
          previous.cols != metadata.cols) {
        throw const FormatException('terminal delta dimensions changed');
      }
      lines = List<TerminalSnapshotRow>.of(previous.lines, growable: false);
      for (final patch in rows) {
        if (patch.rowIndex < 0 || patch.rowIndex >= lines.length) {
          throw const FormatException('terminal row index is out of range');
        }
        lines[patch.rowIndex] = patch.row;
      }
    }
    return metadata.snapshot(frameId: frameId, lines: lines);
  }
}

class TerminalRowPatch {
  final int rowIndex;
  final TerminalSnapshotRow row;

  const TerminalRowPatch({required this.rowIndex, required this.row});
}

List<TerminalSnapshotCell> _decodeTerminalSnapshotCells(Uint8List payload) {
  final reader = _TerminalBinaryReader(payload);
  final count = reader.readUint16();
  final cells = <TerminalSnapshotCell>[];
  for (var i = 0; i < count; i++) {
    final col = reader.readUint16();
    final widthCells = reader.readUint8();
    final flags = reader.readUint8();
    final foregroundArgb = reader.readUint32();
    final backgroundArgb = reader.readUint32();
    final textLength = reader.readUint16();
    final text = textLength == 0
        ? ''
        : utf8.decode(reader.readBytesView(textLength));
    cells.add(
      TerminalSnapshotCell(
        col: col,
        widthCells: widthCells,
        text: text,
        foregroundArgb: foregroundArgb,
        backgroundArgb: backgroundArgb,
        drawsBackground: flags & 1 != 0,
        bold: flags & (1 << 1) != 0,
        italic: flags & (1 << 2) != 0,
        invisible: flags & (1 << 3) != 0,
        hasHyperlink: flags & (1 << 4) != 0,
      ),
    );
  }
  if (!reader.isAtEnd) {
    throw const FormatException('terminal row has trailing bytes');
  }
  return List<TerminalSnapshotCell>.unmodifiable(cells);
}

class _TerminalBinaryWriter {
  Uint8List _bytes = Uint8List(4096);
  late ByteData _data = ByteData.sublistView(_bytes);
  int length = 0;

  void writeUint8(int value) {
    _ensure(1);
    _data.setUint8(length, value);
    length++;
  }

  void writeUint16(int value) {
    _ensure(2);
    _data.setUint16(length, value, Endian.little);
    length += 2;
  }

  void writeUint32(int value) {
    _ensure(4);
    _data.setUint32(length, value, Endian.little);
    length += 4;
  }

  void writeInt32(int value) {
    _ensure(4);
    _data.setInt32(length, value, Endian.little);
    length += 4;
  }

  void writeUint64(int value) {
    _ensure(8);
    _data.setUint64(length, value, Endian.little);
    length += 8;
  }

  void writeInt64(int value) {
    _ensure(8);
    _data.setInt64(length, value, Endian.little);
    length += 8;
  }

  void writeBytes(List<int> value) {
    _ensure(value.length);
    _bytes.setRange(length, length + value.length, value);
    length += value.length;
  }

  void patchUint16(int offset, int value) {
    _data.setUint16(offset, value, Endian.little);
  }

  void patchUint32(int offset, int value) {
    _data.setUint32(offset, value, Endian.little);
  }

  Uint8List takeBytes() {
    return Uint8List.sublistView(_bytes, 0, length);
  }

  void _ensure(int additional) {
    final required = length + additional;
    if (required <= _bytes.length) return;
    var capacity = _bytes.length * 2;
    if (capacity < required) capacity = required;
    final next = Uint8List(capacity)..setRange(0, length, _bytes);
    _bytes = next;
    _data = ByteData.sublistView(_bytes);
  }
}

class _TerminalBinaryReader {
  final Uint8List _bytes;
  late final ByteData _data = ByteData.sublistView(_bytes);
  int _offset = 0;

  _TerminalBinaryReader(this._bytes);

  bool get isAtEnd => _offset == _bytes.length;

  int readUint8() {
    _require(1);
    return _data.getUint8(_offset++);
  }

  int readUint16() {
    _require(2);
    final value = _data.getUint16(_offset, Endian.little);
    _offset += 2;
    return value;
  }

  int readUint32() {
    _require(4);
    final value = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int readInt32() {
    _require(4);
    final value = _data.getInt32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int readUint64() {
    _require(8);
    final value = _data.getUint64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  int readInt64() {
    _require(8);
    final value = _data.getInt64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  Uint8List readBytesView(int length) {
    _require(length);
    final result = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return result;
  }

  void _require(int length) {
    if (length < 0 || _offset + length > _bytes.length) {
      throw const FormatException('truncated terminal frame');
    }
  }
}

bool _isSelectableWordCell(TerminalSnapshotCell cell) {
  return !cell.invisible && cell.text.trim().isNotEmpty;
}

class TerminalCellPoint implements Comparable<TerminalCellPoint> {
  final int row;
  final int col;

  const TerminalCellPoint({required this.row, required this.col});

  @override
  int compareTo(TerminalCellPoint other) {
    final rowCompare = row.compareTo(other.row);
    if (rowCompare != 0) return rowCompare;
    return col.compareTo(other.col);
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalCellPoint && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);
}

class TerminalSelection {
  final TerminalCellPoint base;
  final TerminalCellPoint extent;

  const TerminalSelection({required this.base, required this.extent});

  TerminalSelection get normalized {
    if (base.compareTo(extent) <= 0) return this;
    return TerminalSelection(base: extent, extent: base);
  }

  ({int startCol, int endCol})? columnsForRow(int row, int cols) {
    if (cols <= 0) return null;
    final range = normalized;
    if (row < range.base.row || row > range.extent.row) return null;
    final startCol = row == range.base.row ? range.base.col : 0;
    final endCol = row == range.extent.row ? range.extent.col : cols - 1;
    return (
      startCol: _clampInt(startCol, 0, cols - 1),
      endCol: _clampInt(endCol, 0, cols - 1),
    );
  }

  bool intersectsCell({
    required int row,
    required int col,
    required int widthCells,
    required int cols,
  }) {
    final range = columnsForRow(row, cols);
    if (range == null) return false;
    final cellEnd = col + (widthCells <= 0 ? 1 : widthCells) - 1;
    return cellEnd >= range.startCol && col <= range.endCol;
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalSelection &&
      other.base == base &&
      other.extent == extent;

  @override
  int get hashCode => Object.hash(base, extent);
}

int _clampInt(int value, int min, int max) {
  if (max < min) return min;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}
