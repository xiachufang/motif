import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'ghostty_bindings.g.dart';
import 'terminal_snapshot.dart';

class TerminalState {
  late GhosttyTerminal _terminal;
  late GhosttyRenderState _renderState;
  late final Pointer<GhosttyRenderStateRowIterator> _rowIteratorPtr;
  late final Pointer<GhosttyRenderStateRowCells> _rowCellsPtr;
  late GhosttyKeyEncoder _keyEncoder;
  late GhosttyKeyEvent _keyEvent;
  late GhosttyMouseEncoder _mouseEncoder;
  late GhosttyMouseEvent _mouseEvent;

  // Effect callbacks. The terminal invokes these synchronously during
  // ghostty_terminal_vt_write() to handle sequences that require a response
  // (e.g. device attributes / status report queries). Without them, programs
  // like fish that probe terminal capabilities on startup block until they
  // time out (~10s). Kept as fields so they can be closed in dispose().
  late final NativeCallable<GhosttyTerminalWritePtyFnFunction>
  _writePtyCallable;
  late final NativeCallable<GhosttyTerminalDeviceAttributesFnFunction>
  _deviceAttrsCallable;

  int cols = 0;
  int rows = 0;

  /// Bytes the engine wants to send to the host (key/mouse/focus encodings,
  /// query responses) are handed to this sink. Motif owns the remote PTY and
  /// relays these over its WebSocket; incoming output arrives via [feedBytes].
  final void Function(Uint8List bytes) onHostWrite;

  final Pointer<Uint8> _keyBuf = calloc.allocate<Uint8>(256);
  final Pointer<Size> _keyLen = calloc<Size>();
  final Pointer<Uint32> _graphemeBuf = calloc<Uint32>(32);
  final Pointer<Uint32> _graphemeLen = calloc<Uint32>();

  TerminalState({required this.onHostWrite});

  /// Hand engine output to the host sink (the remote PTY, over the network).
  void _writeOut(Pointer<Uint8> buf, int len) {
    if (len <= 0) return;
    onHostWrite(Uint8List.fromList(buf.asTypedList(len)));
  }

  void init(int cols, int rows) {
    this.cols = cols;
    this.rows = rows;

    // Create terminal
    final termPtr = calloc<GhosttyTerminal>();
    final opts = calloc<GhosttyTerminalOptions>();
    opts.ref.cols = cols;
    opts.ref.rows = rows;
    opts.ref.max_scrollback = 10000;
    ghostty_terminal_new(nullptr, termPtr, opts.ref);
    _terminal = termPtr.value;
    calloc.free(opts);
    calloc.free(termPtr);

    // Register effect callbacks so the terminal can answer query sequences.
    // isolateLocal (not listener) because they fire synchronously inside
    // ghostty_terminal_vt_write() and the data pointers are only valid for
    // the duration of the call.
    _writePtyCallable =
        NativeCallable<GhosttyTerminalWritePtyFnFunction>.isolateLocal(
          _onWritePty,
        );
    _deviceAttrsCallable =
        NativeCallable<GhosttyTerminalDeviceAttributesFnFunction>.isolateLocal(
          _onDeviceAttributes,
          exceptionalReturn: false,
        );
    ghostty_terminal_set(
      _terminal,
      GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_WRITE_PTY,
      _writePtyCallable.nativeFunction.cast(),
    );
    ghostty_terminal_set(
      _terminal,
      GhosttyTerminalOption.GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
      _deviceAttrsCallable.nativeFunction.cast(),
    );

    // Create render state
    final rsPtr = calloc<GhosttyRenderState>();
    ghostty_render_state_new(nullptr, rsPtr);
    _renderState = rsPtr.value;
    calloc.free(rsPtr);

    // Create row iterator
    _rowIteratorPtr = calloc<GhosttyRenderStateRowIterator>();
    ghostty_render_state_row_iterator_new(nullptr, _rowIteratorPtr);

    // Create row cells
    _rowCellsPtr = calloc<GhosttyRenderStateRowCells>();
    ghostty_render_state_row_cells_new(nullptr, _rowCellsPtr);

    // Create key encoder + event
    final kePtr = calloc<GhosttyKeyEncoder>();
    ghostty_key_encoder_new(nullptr, kePtr);
    _keyEncoder = kePtr.value;
    calloc.free(kePtr);

    final kevtPtr = calloc<GhosttyKeyEvent>();
    ghostty_key_event_new(nullptr, kevtPtr);
    _keyEvent = kevtPtr.value;
    calloc.free(kevtPtr);

    // Create mouse encoder + event
    final mePtr = calloc<GhosttyMouseEncoder>();
    ghostty_mouse_encoder_new(nullptr, mePtr);
    _mouseEncoder = mePtr.value;
    calloc.free(mePtr);

    final mevtPtr = calloc<GhosttyMouseEvent>();
    ghostty_mouse_event_new(nullptr, mevtPtr);
    _mouseEvent = mevtPtr.value;
    calloc.free(mevtPtr);
  }

  /// Feed bytes received from the remote PTY (network mode) into the engine.
  void feedBytes(Uint8List data) {
    if (data.isEmpty) return;
    final ptr = calloc<Uint8>(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    ghostty_terminal_vt_write(_terminal, ptr, data.length);
    calloc.free(ptr);
  }

  void dispose() {
    _writePtyCallable.close();
    _deviceAttrsCallable.close();
    ghostty_mouse_event_free(_mouseEvent);
    ghostty_mouse_encoder_free(_mouseEncoder);
    ghostty_key_event_free(_keyEvent);
    ghostty_key_encoder_free(_keyEncoder);
    ghostty_render_state_row_cells_free(_rowCellsPtr.value);
    ghostty_render_state_row_iterator_free(_rowIteratorPtr.value);
    ghostty_render_state_free(_renderState);
    ghostty_terminal_free(_terminal);
    calloc.free(_keyBuf);
    calloc.free(_keyLen);
    calloc.free(_graphemeBuf);
    calloc.free(_graphemeLen);
    calloc.free(_colorsPtr);
    calloc.free(_stylePtr);
    calloc.free(_cellPtr);
    calloc.free(_cellWidePtr);
    calloc.free(_palettePtr);
    calloc.free(_rowIteratorPtr);
    calloc.free(_rowCellsPtr);
  }

  // Called when the terminal has bytes to send back to the program (query
  // responses, status reports). pty_write copies synchronously, so the data
  // pointer does not need to outlive this call.
  void _onWritePty(
    GhosttyTerminal terminal,
    Pointer<Void> userdata,
    Pointer<Uint8> data,
    int len,
  ) {
    _writeOut(data, len);
  }

  // Answers Device Attributes queries (DA1/DA2/DA3) with a VT220-class
  // response (CSI ? 62 ; 22 c for DA1). Returning true lets the terminal
  // encode the reply and emit it via the write_pty callback above.
  bool _onDeviceAttributes(
    GhosttyTerminal terminal,
    Pointer<Void> userdata,
    Pointer<GhosttyDeviceAttributes> outAttrs,
  ) {
    final attrs = outAttrs.ref;
    attrs.primary.conformance_level = 62; // VT220
    attrs.primary.features[0] = 22; // ANSI color
    attrs.primary.num_features = 1;
    attrs.secondary.device_type = 1; // VT220
    attrs.secondary.firmware_version = 10;
    attrs.secondary.rom_cartridge = 0;
    attrs.tertiary.unit_id = 0;
    return true;
  }

  void updateRenderState() {
    ghostty_render_state_update(_renderState, _terminal);
    _paletteDirty = true;
  }

  GhosttyRenderStateDirty getDirty() {
    final out = calloc<Int32>();
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_DIRTY,
      out.cast(),
    );
    final val = GhosttyRenderStateDirty.fromValue(out.value);
    calloc.free(out);
    return val;
  }

  void setDirty(GhosttyRenderStateDirty dirty) {
    final val = calloc<Int32>();
    val.value = dirty.value;
    ghostty_render_state_set(
      _renderState,
      GhosttyRenderStateOption.GHOSTTY_RENDER_STATE_OPTION_DIRTY,
      val.cast(),
    );
    calloc.free(val);
  }

  GhosttyRenderStateColors getColors() {
    final colors = calloc<GhosttyRenderStateColors>();
    colors.ref.size = sizeOf<GhosttyRenderStateColors>();
    ghostty_render_state_colors_get(_renderState, colors);
    final result = colors.ref;
    // Copy values before freeing - we need to return the struct by value
    // Actually GhosttyRenderStateColors is a Struct, return the pointer
    // and let caller free it. But that's error-prone. Instead, let's
    // keep a pre-allocated one.
    return result;
  }

  // Pre-allocated colors struct for reuse
  late final Pointer<GhosttyRenderStateColors> _colorsPtr = () {
    final p = calloc<GhosttyRenderStateColors>();
    p.ref.size = sizeOf<GhosttyRenderStateColors>();
    return p;
  }();

  GhosttyRenderStateColors get colors {
    ghostty_render_state_colors_get(_renderState, _colorsPtr);
    return _colorsPtr.ref;
  }

  void populateRowIterator() {
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
      _rowIteratorPtr.cast(),
    );
  }

  bool rowIteratorNext() {
    return ghostty_render_state_row_iterator_next(_rowIteratorPtr.value);
  }

  bool isRowDirty() {
    final out = calloc<Bool>();
    ghostty_render_state_row_get(
      _rowIteratorPtr.value,
      GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
      out.cast(),
    );
    final val = out.value;
    calloc.free(out);
    return val;
  }

  void setRowDirty(bool dirty) {
    final val = calloc<Bool>();
    val.value = dirty;
    ghostty_render_state_row_set(
      _rowIteratorPtr.value,
      GhosttyRenderStateRowOption.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
      val.cast(),
    );
    calloc.free(val);
  }

  void populateRowCells() {
    ghostty_render_state_row_get(
      _rowIteratorPtr.value,
      GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
      _rowCellsPtr.cast(),
    );
  }

  bool rowCellsNext() {
    return ghostty_render_state_row_cells_next(_rowCellsPtr.value);
  }

  GhosttyStyle getCellStyle() {
    final style = calloc<GhosttyStyle>();
    style.ref.size = sizeOf<GhosttyStyle>();
    ghostty_render_state_row_cells_get(
      _rowCellsPtr.value,
      GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
      style.cast(),
    );
    final result = style.ref;
    calloc.free(style);
    return result;
  }

  // Pre-allocated style for reuse
  late final Pointer<GhosttyStyle> _stylePtr = () {
    final p = calloc<GhosttyStyle>();
    p.ref.size = sizeOf<GhosttyStyle>();
    return p;
  }();

  GhosttyStyle get cellStyle {
    ghostty_render_state_row_cells_get(
      _rowCellsPtr.value,
      GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
      _stylePtr.cast(),
    );
    return _stylePtr.ref;
  }

  // Pre-allocated cell handle + wide value for reuse
  late final Pointer<GhosttyCell> _cellPtr = calloc<GhosttyCell>();
  late final Pointer<Int32> _cellWidePtr = calloc<Int32>();

  /// The wide property of the current cell (narrow / wide / spacer).
  GhosttyCellWide get cellWide {
    ghostty_render_state_row_cells_get(
      _rowCellsPtr.value,
      GhosttyRenderStateRowCellsData.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
      _cellPtr.cast(),
    );
    ghostty_cell_get(
      _cellPtr.value,
      GhosttyCellData.GHOSTTY_CELL_DATA_WIDE,
      _cellWidePtr.cast(),
    );
    return GhosttyCellWide.fromValue(_cellWidePtr.value);
  }

  int getCellGraphemeLen() {
    ghostty_render_state_row_cells_get(
      _rowCellsPtr.value,
      GhosttyRenderStateRowCellsData
          .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
      _graphemeLen.cast(),
    );
    return _graphemeLen.value;
  }

  String getCellGrapheme(int len) {
    if (len == 0) return '';
    ghostty_render_state_row_cells_get(
      _rowCellsPtr.value,
      GhosttyRenderStateRowCellsData
          .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
      _graphemeBuf.cast(),
    );
    final codepoints = <int>[];
    for (var i = 0; i < len; i++) {
      codepoints.add(_graphemeBuf[i]);
    }
    return String.fromCharCodes(codepoints);
  }

  void resize(int newCols, int newRows, int cellWidthPx, int cellHeightPx) {
    if (newCols == cols && newRows == rows) return;
    cols = newCols;
    rows = newRows;
    ghostty_terminal_resize(
      _terminal,
      newCols,
      newRows,
      cellWidthPx,
      cellHeightPx,
    );
    // The remote owns the PTY size; the caller issues an RPC pty.resize.
  }

  // Cursor info
  bool get cursorVisible {
    final out = calloc<Bool>();
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
      out.cast(),
    );
    final val = out.value;
    calloc.free(out);
    return val;
  }

  bool get cursorInViewport {
    final out = calloc<Bool>();
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData
          .GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
      out.cast(),
    );
    final val = out.value;
    calloc.free(out);
    return val;
  }

  int get cursorX {
    final out = calloc<Uint16>();
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
      out.cast(),
    );
    final val = out.value;
    calloc.free(out);
    return val;
  }

  int get cursorY {
    final out = calloc<Uint16>();
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
      out.cast(),
    );
    final val = out.value;
    calloc.free(out);
    return val;
  }

  GhosttyRenderStateCursorVisualStyle get cursorStyle {
    final out = calloc<Int32>();
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
      out.cast(),
    );
    final val = GhosttyRenderStateCursorVisualStyle.fromValue(out.value);
    calloc.free(out);
    return val;
  }

  bool get mouseTrackingActive {
    final out = calloc<Bool>();
    final result = ghostty_terminal_get(
      _terminal,
      GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
      out.cast(),
    );
    final val = result == GhosttyResult.GHOSTTY_SUCCESS && out.value;
    calloc.free(out);
    return val;
  }

  bool get alternateScreenActive {
    final out = calloc<Int32>();
    final result = ghostty_terminal_get(
      _terminal,
      GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,
      out.cast(),
    );
    final val =
        result == GhosttyResult.GHOSTTY_SUCCESS &&
        out.value ==
            GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_ALTERNATE.value;
    calloc.free(out);
    return val;
  }

  // Key encoding
  void encodeKeyAndWrite(
    GhosttyKey key,
    GhosttyKeyAction action,
    int mods,
    String? text, {
    int unshiftedCodepoint = 0,
  }) {
    ghostty_key_encoder_setopt_from_terminal(_keyEncoder, _terminal);
    ghostty_key_event_set_key(_keyEvent, key);
    ghostty_key_event_set_action(_keyEvent, action);
    ghostty_key_event_set_mods(_keyEvent, mods);
    ghostty_key_event_set_unshifted_codepoint(_keyEvent, unshiftedCodepoint);

    if (text != null && text.isNotEmpty) {
      final utf8 = text.toNativeUtf8();
      ghostty_key_event_set_utf8(_keyEvent, utf8.cast(), text.length);
      final result = ghostty_key_encoder_encode(
        _keyEncoder,
        _keyEvent,
        _keyBuf.cast(),
        256,
        _keyLen,
      );
      calloc.free(utf8);
      if (result == GhosttyResult.GHOSTTY_SUCCESS && _keyLen.value > 0) {
        _writeOut(_keyBuf, _keyLen.value);
      }
    } else {
      ghostty_key_event_set_utf8(_keyEvent, nullptr, 0);
      final result = ghostty_key_encoder_encode(
        _keyEncoder,
        _keyEvent,
        _keyBuf.cast(),
        256,
        _keyLen,
      );
      if (result == GhosttyResult.GHOSTTY_SUCCESS && _keyLen.value > 0) {
        _writeOut(_keyBuf, _keyLen.value);
      }
    }
  }

  // Mouse encoding
  void encodeMouseAndWrite(
    GhosttyMouseAction action,
    GhosttyMouseButton button,
    int mods,
    double x,
    double y,
  ) {
    ghostty_mouse_encoder_setopt_from_terminal(_mouseEncoder, _terminal);
    ghostty_mouse_event_set_action(_mouseEvent, action);
    if (button == GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_UNKNOWN) {
      ghostty_mouse_event_clear_button(_mouseEvent);
    } else {
      ghostty_mouse_event_set_button(_mouseEvent, button);
    }
    ghostty_mouse_event_set_mods(_mouseEvent, mods);

    final pos = calloc<GhosttyMousePosition>();
    pos.ref.x = x;
    pos.ref.y = y;
    ghostty_mouse_event_set_position(_mouseEvent, pos.ref);
    calloc.free(pos);

    final result = ghostty_mouse_encoder_encode(
      _mouseEncoder,
      _mouseEvent,
      _keyBuf.cast(),
      256,
      _keyLen,
    );
    if (result == GhosttyResult.GHOSTTY_SUCCESS && _keyLen.value > 0) {
      _writeOut(_keyBuf, _keyLen.value);
    }
  }

  // Focus encoding
  void encodeFocusAndWrite(bool gained) {
    final event = gained
        ? GhosttyFocusEvent.GHOSTTY_FOCUS_GAINED
        : GhosttyFocusEvent.GHOSTTY_FOCUS_LOST;
    final result = ghostty_focus_encode(event, _keyBuf.cast(), 256, _keyLen);
    if (result == GhosttyResult.GHOSTTY_SUCCESS && _keyLen.value > 0) {
      _writeOut(_keyBuf, _keyLen.value);
    }
  }

  // Scroll
  void scroll(int delta) {
    final sv = calloc<GhosttyTerminalScrollViewport>();
    sv.ref.tagAsInt =
        GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_DELTA.value;
    sv.ref.value.delta = delta;
    ghostty_terminal_scroll_viewport(_terminal, sv.ref);
    calloc.free(sv);
  }

  void scrollToBottom() {
    final sv = calloc<GhosttyTerminalScrollViewport>();
    sv.ref.tagAsInt =
        GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_BOTTOM.value;
    ghostty_terminal_scroll_viewport(_terminal, sv.ref);
    calloc.free(sv);
  }

  // Update mouse encoder size
  void setMouseEncoderSize(
    int screenWidth,
    int screenHeight,
    int cellWidth,
    int cellHeight,
    int paddingLeft,
    int paddingTop,
  ) {
    final size = calloc<GhosttyMouseEncoderSize>();
    size.ref.size = sizeOf<GhosttyMouseEncoderSize>();
    size.ref.screen_width = screenWidth;
    size.ref.screen_height = screenHeight;
    size.ref.cell_width = cellWidth;
    size.ref.cell_height = cellHeight;
    size.ref.padding_left = paddingLeft;
    size.ref.padding_top = paddingTop;
    size.ref.padding_right = 0;
    size.ref.padding_bottom = 0;
    ghostty_mouse_encoder_setopt(
      _mouseEncoder,
      GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
      size.cast(),
    );
    calloc.free(size);
  }

  // Cache palette
  late final Pointer<GhosttyColorRgb> _palettePtr = calloc<GhosttyColorRgb>(
    256,
  );
  bool _paletteDirty = true;

  void _refreshPalette() {
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE,
      _palettePtr.cast(),
    );
    _paletteDirty = false;
  }

  (int r, int g, int b) paletteColor(int index) {
    if (_paletteDirty) _refreshPalette();
    final c = (_palettePtr + index).ref;
    return (c.r, c.g, c.b);
  }

  void markPaletteDirty() {
    _paletteDirty = true;
  }

  TerminalSnapshot snapshot({
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
  }) {
    final colors = this.colors;
    final bgColor = defaultBackgroundArgb;
    final fgDefault = defaultForegroundArgb;
    final cursorColor = colors.cursor_has_value
        ? _rgbArgb(colors.cursor.r, colors.cursor.g, colors.cursor.b)
        : fgDefault;

    final lines = <TerminalSnapshotRow>[];
    populateRowIterator();
    while (rowIteratorNext()) {
      final rowText = StringBuffer();
      final cells = <TerminalSnapshotCell>[];
      populateRowCells();
      var colIdx = 0;
      while (rowCellsNext()) {
        final wide = cellWide;
        final graphemeLen = getCellGraphemeLen();
        final grapheme = graphemeLen > 0 ? getCellGrapheme(graphemeLen) : '';
        rowText.write(grapheme);

        if (wide == GhosttyCellWide.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
          colIdx++;
          continue;
        }

        final style = cellStyle;
        var fg = _resolveSnapshotColor(style.fg_color, fgDefault);
        var bg = _resolveSnapshotColor(style.bg_color, bgColor);
        if (style.inverse) {
          final tmp = fg;
          fg = bg;
          bg = tmp;
        }
        if (style.faint) {
          fg = _withAlpha(fg, 0x80);
        }
        final drawsBackground = bg != bgColor;
        if (grapheme.isNotEmpty || drawsBackground) {
          cells.add(
            TerminalSnapshotCell(
              col: colIdx,
              widthCells: wide == GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE
                  ? 2
                  : 1,
              text: grapheme,
              foregroundArgb: fg,
              backgroundArgb: bg,
              drawsBackground: drawsBackground,
              bold: style.bold,
              italic: style.italic,
              invisible: style.invisible,
            ),
          );
        }
        colIdx++;
      }
      setRowDirty(false);
      lines.add(TerminalSnapshotRow(text: rowText.toString(), cells: cells));
    }

    final snapshot = TerminalSnapshot(
      cols: cols,
      rows: rows,
      backgroundArgb: bgColor,
      foregroundArgb: fgDefault,
      cursorArgb: cursorColor,
      cursorVisible: cursorVisible,
      cursorInViewport: cursorInViewport,
      cursorX: cursorInViewport ? cursorX : -1,
      cursorY: cursorInViewport ? cursorY : -1,
      cursorStyle: cursorStyle.value,
      mouseTrackingActive: mouseTrackingActive,
      alternateScreenActive: alternateScreenActive,
      lines: lines,
    );
    setDirty(GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE);
    return snapshot;
  }

  int _resolveSnapshotColor(GhosttyStyleColor styleColor, int defaultColor) {
    switch (styleColor.tag) {
      case GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_NONE:
        return defaultColor;
      case GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_RGB:
        final rgb = styleColor.value.rgb;
        return _rgbArgb(rgb.r, rgb.g, rgb.b);
      case GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_PALETTE:
        final idx = styleColor.value.palette;
        final (r, g, b) = paletteColor(idx);
        return _rgbArgb(r, g, b);
      case GhosttyStyleColorTag.GHOSTTY_STYLE_COLOR_TAG_MAX_VALUE:
        return defaultColor;
    }
  }

  int _rgbArgb(int r, int g, int b) => 0xff000000 | (r << 16) | (g << 8) | b;

  int _withAlpha(int argb, int alpha) => (argb & 0x00ffffff) | (alpha << 24);

  // Write raw bytes to the host (the remote PTY, via the network sink).
  void writeToPty(Uint8List data) {
    if (data.isEmpty) return;
    final ptr = calloc<Uint8>(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    _writeOut(ptr, data.length);
    calloc.free(ptr);
  }
}
