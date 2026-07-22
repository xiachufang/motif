import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'ghostty_bindings.g.dart';
import 'terminal_snapshot.dart';

class TerminalState {
  static const int _bracketedPasteMode = 2004;
  late GhosttyTerminal _terminal;
  late GhosttyRenderState _renderState;
  late final Pointer<GhosttyRenderStateRowIterator> _rowIteratorPtr;
  late final Pointer<GhosttyRenderStateRowCells> _rowCellsPtr;
  late GhosttyKeyEncoder _keyEncoder;
  late GhosttyKeyEvent _keyEvent;
  late GhosttyMouseEncoder _mouseEncoder;
  late GhosttyMouseEvent _mouseEvent;
  GhosttyTrackedGridRef? _selectionStartRef;
  GhosttyTrackedGridRef? _selectionEndRef;

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
  Pointer<Uint8> _feedBuf = calloc<Uint8>(16 * 1024);
  int _feedBufCapacity = 16 * 1024;
  Pointer<Uint8> _keyTextBuf = calloc<Uint8>(64);
  int _keyTextBufCapacity = 64;
  Pointer<Uint8> _pasteInputBuf = calloc<Uint8>(4096);
  int _pasteInputCapacity = 4096;
  Pointer<Uint8> _pasteOutputBuf = calloc<Uint8>(4096 + 12);
  int _pasteOutputCapacity = 4096 + 12;
  final Pointer<Bool> _pasteBracketedPtr = calloc<Bool>();
  final Pointer<Uint32> _graphemeBuf = calloc<Uint32>(32);
  final Pointer<Uint32> _graphemeLen = calloc<Uint32>();
  final Pointer<Int32> _dirtyPtr = calloc<Int32>();
  final Pointer<Bool> _rowDirtyPtr = calloc<Bool>();
  final Pointer<Bool> _rowDirtyValuePtr = calloc<Bool>();
  final Pointer<Size> _multiWrittenPtr = calloc<Size>();
  final Pointer<Bool> _cursorVisiblePtr = calloc<Bool>();
  final Pointer<Bool> _cursorInViewportPtr = calloc<Bool>();
  final Pointer<Uint16> _cursorXPtr = calloc<Uint16>();
  final Pointer<Uint16> _cursorYPtr = calloc<Uint16>();
  final Pointer<Int32> _cursorStylePtr = calloc<Int32>();
  final Pointer<Bool> _cursorHasColorPtr = calloc<Bool>();
  final Pointer<GhosttyColorRgb> _cursorColorPtr = calloc<GhosttyColorRgb>();
  final Pointer<Bool> _mouseTrackingPtr = calloc<Bool>();
  final Pointer<Int32> _activeScreenPtr = calloc<Int32>();
  final Pointer<GhosttyTerminalScrollbar> _scrollbarPtr =
      calloc<GhosttyTerminalScrollbar>();
  final Pointer<GhosttyTerminalScrollViewport> _scrollViewportPtr =
      calloc<GhosttyTerminalScrollViewport>();
  final Pointer<GhosttyMousePosition> _mousePositionPtr =
      calloc<GhosttyMousePosition>();
  final Pointer<GhosttyMouseEncoderSize> _mouseEncoderSizePtr =
      calloc<GhosttyMouseEncoderSize>();
  final Pointer<GhosttyBuffer> _cellUtf8BufferPtr = calloc<GhosttyBuffer>();
  Pointer<Uint8> _cellUtf8Bytes = calloc<Uint8>(64);
  int _cellUtf8Capacity = 64;
  late final Pointer<UnsignedInt> _rowGetKeys;
  late final Pointer<Pointer<Void>> _rowGetValues;
  late final Pointer<UnsignedInt> _cellGetKeys;
  late final Pointer<Pointer<Void>> _cellGetValues;
  late final Pointer<UnsignedInt> _cursorGetKeys;
  late final Pointer<Pointer<Void>> _cursorGetValues;
  late final Pointer<UnsignedInt> _cursorPositionKeys;
  late final Pointer<Pointer<Void>> _cursorPositionValues;
  late final Pointer<UnsignedInt> _terminalGetKeys;
  late final Pointer<Pointer<Void>> _terminalGetValues;

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
    _initializeFrameScratch();

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

  void _initializeFrameScratch() {
    _rowGetKeys = calloc<UnsignedInt>(2);
    _rowGetValues = calloc<Pointer<Void>>(2);
    _rowGetKeys[0] =
        GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY.value;
    _rowGetKeys[1] =
        GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS.value;
    _rowGetValues[0] = _rowDirtyPtr.cast();
    _rowGetValues[1] = _rowCellsPtr.cast();

    _cellGetKeys = calloc<UnsignedInt>(3);
    _cellGetValues = calloc<Pointer<Void>>(3);
    _cellGetKeys[0] = GhosttyRenderStateRowCellsData
        .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW
        .value;
    _cellGetKeys[1] = GhosttyRenderStateRowCellsData
        .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE
        .value;
    _cellGetKeys[2] = GhosttyRenderStateRowCellsData
        .GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8
        .value;
    _cellGetValues[0] = _cellPtr.cast();
    _cellGetValues[1] = _stylePtr.cast();
    _cellGetValues[2] = _cellUtf8BufferPtr.cast();
    _cellUtf8BufferPtr.ref
      ..ptr = _cellUtf8Bytes
      ..cap = _cellUtf8Capacity
      ..len = 0;

    _cursorGetKeys = calloc<UnsignedInt>(4);
    _cursorGetValues = calloc<Pointer<Void>>(4);
    _cursorGetKeys[0] =
        GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE.value;
    _cursorGetKeys[1] = GhosttyRenderStateData
        .GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE
        .value;
    _cursorGetKeys[2] = GhosttyRenderStateData
        .GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE
        .value;
    _cursorGetKeys[3] = GhosttyRenderStateData
        .GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE
        .value;
    _cursorGetValues[0] = _cursorVisiblePtr.cast();
    _cursorGetValues[1] = _cursorInViewportPtr.cast();
    _cursorGetValues[2] = _cursorStylePtr.cast();
    _cursorGetValues[3] = _cursorHasColorPtr.cast();

    _cursorPositionKeys = calloc<UnsignedInt>(2);
    _cursorPositionValues = calloc<Pointer<Void>>(2);
    _cursorPositionKeys[0] = GhosttyRenderStateData
        .GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X
        .value;
    _cursorPositionKeys[1] = GhosttyRenderStateData
        .GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y
        .value;
    _cursorPositionValues[0] = _cursorXPtr.cast();
    _cursorPositionValues[1] = _cursorYPtr.cast();

    _terminalGetKeys = calloc<UnsignedInt>(3);
    _terminalGetValues = calloc<Pointer<Void>>(3);
    _terminalGetKeys[0] =
        GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING.value;
    _terminalGetKeys[1] =
        GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN.value;
    _terminalGetKeys[2] =
        GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBAR.value;
    _terminalGetValues[0] = _mouseTrackingPtr.cast();
    _terminalGetValues[1] = _activeScreenPtr.cast();
    _terminalGetValues[2] = _scrollbarPtr.cast();
  }

  /// Feed bytes received from the remote PTY (network mode) into the engine.
  void feedBytes(Uint8List data) {
    if (data.isEmpty) return;
    // Treat the viewport as an explicit user choice across output. A viewport
    // at the live bottom follows new rows; a viewport in history stays at the
    // same absolute offset. Ghostty currently behaves this way too, but doing
    // it at the feed boundary makes the contract independent of renderer
    // defaults and keeps burst/coalesced worker frames from changing it.
    final wasAlternateScreen = alternateScreenActive;
    final viewportBefore = scrollbarMetrics;
    final maxOffsetBefore = viewportBefore.total > viewportBefore.length
        ? viewportBefore.total - viewportBefore.length
        : 0;
    final followLatest = viewportBefore.offset >= maxOffsetBefore;
    if (data.length > _feedBufCapacity) {
      calloc.free(_feedBuf);
      _feedBufCapacity = _nextBufferCapacity(data.length);
      _feedBuf = calloc<Uint8>(_feedBufCapacity);
    }
    _feedBuf.asTypedList(data.length).setAll(0, data);
    ghostty_terminal_vt_write(_terminal, _feedBuf, data.length);
    // Let Ghostty own viewport restoration when the output itself switches
    // between primary and alternate screens (for example entering/leaving
    // vim). The follow/preserve rule applies while staying on one screen.
    if (wasAlternateScreen != alternateScreenActive) return;
    if (followLatest) {
      scrollToBottom();
    } else {
      scrollToOffset(viewportBefore.offset);
    }
  }

  void dispose() {
    clearTrackedSelection();
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
    calloc.free(_feedBuf);
    calloc.free(_keyTextBuf);
    calloc.free(_pasteInputBuf);
    calloc.free(_pasteOutputBuf);
    calloc.free(_pasteBracketedPtr);
    calloc.free(_graphemeBuf);
    calloc.free(_graphemeLen);
    calloc.free(_dirtyPtr);
    calloc.free(_rowDirtyPtr);
    calloc.free(_rowDirtyValuePtr);
    calloc.free(_multiWrittenPtr);
    calloc.free(_cursorVisiblePtr);
    calloc.free(_cursorInViewportPtr);
    calloc.free(_cursorXPtr);
    calloc.free(_cursorYPtr);
    calloc.free(_cursorStylePtr);
    calloc.free(_cursorHasColorPtr);
    calloc.free(_cursorColorPtr);
    calloc.free(_mouseTrackingPtr);
    calloc.free(_activeScreenPtr);
    calloc.free(_scrollbarPtr);
    calloc.free(_scrollViewportPtr);
    calloc.free(_mousePositionPtr);
    calloc.free(_mouseEncoderSizePtr);
    calloc.free(_cellUtf8BufferPtr);
    calloc.free(_cellUtf8Bytes);
    calloc.free(_rowGetKeys);
    calloc.free(_rowGetValues);
    calloc.free(_cellGetKeys);
    calloc.free(_cellGetValues);
    calloc.free(_cursorGetKeys);
    calloc.free(_cursorGetValues);
    calloc.free(_cursorPositionKeys);
    calloc.free(_cursorPositionValues);
    calloc.free(_terminalGetKeys);
    calloc.free(_terminalGetValues);
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
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_DIRTY,
      _dirtyPtr.cast(),
    );
    return GhosttyRenderStateDirty.fromValue(_dirtyPtr.value);
  }

  void setDirty(GhosttyRenderStateDirty dirty) {
    _dirtyPtr.value = dirty.value;
    ghostty_render_state_set(
      _renderState,
      GhosttyRenderStateOption.GHOSTTY_RENDER_STATE_OPTION_DIRTY,
      _dirtyPtr.cast(),
    );
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
    ghostty_render_state_row_get(
      _rowIteratorPtr.value,
      GhosttyRenderStateRowData.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
      _rowDirtyPtr.cast(),
    );
    return _rowDirtyPtr.value;
  }

  void setRowDirty(bool dirty) {
    _rowDirtyValuePtr.value = dirty;
    ghostty_render_state_row_set(
      _rowIteratorPtr.value,
      GhosttyRenderStateRowOption.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
      _rowDirtyValuePtr.cast(),
    );
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
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
      _cursorVisiblePtr.cast(),
    );
    return _cursorVisiblePtr.value;
  }

  bool get cursorInViewport {
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData
          .GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
      _cursorInViewportPtr.cast(),
    );
    return _cursorInViewportPtr.value;
  }

  int get cursorX {
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
      _cursorXPtr.cast(),
    );
    return _cursorXPtr.value;
  }

  int get cursorY {
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
      _cursorYPtr.cast(),
    );
    return _cursorYPtr.value;
  }

  GhosttyRenderStateCursorVisualStyle get cursorStyle {
    ghostty_render_state_get(
      _renderState,
      GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
      _cursorStylePtr.cast(),
    );
    return GhosttyRenderStateCursorVisualStyle.fromValue(_cursorStylePtr.value);
  }

  bool get mouseTrackingActive {
    final result = ghostty_terminal_get(
      _terminal,
      GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
      _mouseTrackingPtr.cast(),
    );
    return result == GhosttyResult.GHOSTTY_SUCCESS && _mouseTrackingPtr.value;
  }

  bool get alternateScreenActive {
    final result = ghostty_terminal_get(
      _terminal,
      GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,
      _activeScreenPtr.cast(),
    );
    return result == GhosttyResult.GHOSTTY_SUCCESS &&
        _activeScreenPtr.value ==
            GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_ALTERNATE.value;
  }

  ({int total, int offset, int length}) get scrollbarMetrics {
    final result = ghostty_terminal_get(
      _terminal,
      GhosttyTerminalData.GHOSTTY_TERMINAL_DATA_SCROLLBAR,
      _scrollbarPtr.cast(),
    );
    final metrics = result == GhosttyResult.GHOSTTY_SUCCESS
        ? (
            total: _scrollbarPtr.ref.total,
            offset: _scrollbarPtr.ref.offset,
            length: _scrollbarPtr.ref.len,
          )
        : (total: rows, offset: 0, length: rows);
    return metrics;
  }

  ({bool visible, bool inViewport, int x, int y, int style, int? colorArgb})
  readCursorState() {
    final result = ghostty_render_state_get_multi(
      _renderState,
      4,
      _cursorGetKeys,
      _cursorGetValues,
      _multiWrittenPtr,
    );
    if (result != GhosttyResult.GHOSTTY_SUCCESS) {
      throw StateError('failed to read terminal cursor state: $result');
    }
    final inViewport = _cursorInViewportPtr.value;
    if (inViewport) {
      final positionResult = ghostty_render_state_get_multi(
        _renderState,
        2,
        _cursorPositionKeys,
        _cursorPositionValues,
        _multiWrittenPtr,
      );
      if (positionResult != GhosttyResult.GHOSTTY_SUCCESS) {
        throw StateError(
          'failed to read terminal cursor position: $positionResult',
        );
      }
    }
    int? colorArgb;
    if (_cursorHasColorPtr.value) {
      final colorResult = ghostty_render_state_get(
        _renderState,
        GhosttyRenderStateData.GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR,
        _cursorColorPtr.cast(),
      );
      if (colorResult != GhosttyResult.GHOSTTY_SUCCESS) {
        throw StateError('failed to read terminal cursor color: $colorResult');
      }
      colorArgb = _rgbArgb(
        _cursorColorPtr.ref.r,
        _cursorColorPtr.ref.g,
        _cursorColorPtr.ref.b,
      );
    }
    return (
      visible: _cursorVisiblePtr.value,
      inViewport: inViewport,
      x: inViewport ? _cursorXPtr.value : -1,
      y: inViewport ? _cursorYPtr.value : -1,
      style: _cursorStylePtr.value,
      colorArgb: colorArgb,
    );
  }

  TerminalFrameMetadata captureFrameMetadata({
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    required ({
      bool visible,
      bool inViewport,
      int x,
      int y,
      int style,
      int? colorArgb,
    })
    cursor,
    TerminalSelection? selection,
  }) {
    final result = ghostty_terminal_get_multi(
      _terminal,
      3,
      _terminalGetKeys,
      _terminalGetValues,
      _multiWrittenPtr,
    );
    if (result != GhosttyResult.GHOSTTY_SUCCESS) {
      throw StateError('failed to read terminal frame metadata: $result');
    }
    return TerminalFrameMetadata(
      cols: cols,
      rows: rows,
      viewportOffset: _scrollbarPtr.ref.offset,
      scrollTotalRows: _scrollbarPtr.ref.total,
      scrollViewportRows: _scrollbarPtr.ref.len,
      backgroundArgb: defaultBackgroundArgb,
      foregroundArgb: defaultForegroundArgb,
      cursorArgb: cursor.colorArgb ?? defaultForegroundArgb,
      cursorVisible: cursor.visible,
      cursorInViewport: cursor.inViewport,
      cursorX: cursor.x,
      cursorY: cursor.y,
      cursorStyle: cursor.style,
      mouseTrackingActive: _mouseTrackingPtr.value,
      alternateScreenActive:
          _activeScreenPtr.value ==
          GhosttyTerminalScreen.GHOSTTY_TERMINAL_SCREEN_ALTERNATE.value,
      selection: selection,
    );
  }

  int get viewportOffset => scrollbarMetrics.offset;

  bool beginTrackedSelection(TerminalCellPoint screenPoint) {
    return setTrackedSelection(screenPoint, screenPoint);
  }

  bool updateTrackedSelectionEnd(TerminalCellPoint screenPoint) {
    final start = _selectionStartRef;
    final end = _selectionEndRef;
    if (start == null || start.address == 0) {
      return beginTrackedSelection(screenPoint);
    }
    if (end == null || end.address == 0) {
      final nextEnd = _trackPoint(
        GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN,
        screenPoint,
      );
      if (nextEnd == null) return false;
      _selectionEndRef = nextEnd;
      return true;
    }
    return _setTrackedPoint(
      end,
      GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN,
      screenPoint,
    );
  }

  bool setTrackedSelection(
    TerminalCellPoint baseScreenPoint,
    TerminalCellPoint extentScreenPoint,
  ) {
    final nextStart = _trackPoint(
      GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN,
      baseScreenPoint,
    );
    if (nextStart == null) return false;
    final nextEnd = _trackPoint(
      GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN,
      extentScreenPoint,
    );
    if (nextEnd == null) {
      ghostty_tracked_grid_ref_free(nextStart);
      return false;
    }
    clearTrackedSelection();
    _selectionStartRef = nextStart;
    _selectionEndRef = nextEnd;
    return true;
  }

  bool selectTrackedWordAtScreenPoint(TerminalCellPoint screenPoint) {
    final ref = calloc<GhosttyGridRef>();
    final opts = calloc<GhosttyTerminalSelectWordOptions>();
    final selection = calloc<GhosttySelection>();
    try {
      ref.ref.size = sizeOf<GhosttyGridRef>();
      if (!_gridRefForPoint(
        GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN,
        screenPoint,
        ref,
      )) {
        clearTrackedSelection();
        return false;
      }

      opts.ref.size = sizeOf<GhosttyTerminalSelectWordOptions>();
      _copyGridRef(opts.ref.ref, ref.ref);
      opts.ref.boundary_codepoints = nullptr;
      opts.ref.boundary_codepoints_len = 0;

      selection.ref.size = sizeOf<GhosttySelection>();
      final result = ghostty_terminal_select_word(_terminal, opts, selection);
      if (result != GhosttyResult.GHOSTTY_SUCCESS) {
        clearTrackedSelection();
        return false;
      }

      return _setTrackedSelectionFromSnapshot(selection.ref);
    } finally {
      calloc.free(selection);
      calloc.free(opts);
      calloc.free(ref);
    }
  }

  void clearTrackedSelection() {
    final start = _selectionStartRef;
    if (start != null && start.address != 0) {
      ghostty_tracked_grid_ref_free(start);
    }
    final end = _selectionEndRef;
    if (end != null && end.address != 0) {
      ghostty_tracked_grid_ref_free(end);
    }
    _selectionStartRef = null;
    _selectionEndRef = null;
  }

  TerminalSelection? trackedSelection() {
    final start = _selectionStartRef;
    final end = _selectionEndRef;
    if (start == null ||
        end == null ||
        start.address == 0 ||
        end.address == 0) {
      return null;
    }
    if (!ghostty_tracked_grid_ref_has_value(start) ||
        !ghostty_tracked_grid_ref_has_value(end)) {
      clearTrackedSelection();
      return null;
    }
    final base = _trackedPoint(start, GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN);
    final extent = _trackedPoint(end, GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN);
    if (base == null || extent == null) return null;
    return TerminalSelection(base: base, extent: extent);
  }

  String? formatTrackedSelection() {
    final selection = _snapshotTrackedSelection();
    if (selection == null) return null;
    final options = calloc<GhosttyTerminalSelectionFormatOptions>();
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      options.ref.size = sizeOf<GhosttyTerminalSelectionFormatOptions>();
      options.ref.emitAsInt =
          GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN.value;
      options.ref.unwrap = true;
      options.ref.trim = true;
      options.ref.selection = selection;

      final result = ghostty_terminal_selection_format_alloc(
        _terminal,
        nullptr,
        options.ref,
        outPtr,
        outLen,
      );
      if (result != GhosttyResult.GHOSTTY_SUCCESS) return null;
      final len = outLen.value;
      if (len <= 0 || outPtr.value.address == 0) return '';
      return utf8.decode(outPtr.value.asTypedList(len));
    } finally {
      if (outPtr.value.address != 0 && outLen.value > 0) {
        ghostty_free(nullptr, outPtr.value, outLen.value);
      }
      calloc.free(outLen);
      calloc.free(outPtr);
      calloc.free(options);
      calloc.free(selection);
    }
  }

  Pointer<GhosttySelection>? _snapshotTrackedSelection() {
    final start = _selectionStartRef;
    final end = _selectionEndRef;
    if (start == null ||
        end == null ||
        start.address == 0 ||
        end.address == 0) {
      return null;
    }
    final selection = calloc<GhosttySelection>();
    final startRef = calloc<GhosttyGridRef>();
    final endRef = calloc<GhosttyGridRef>();
    try {
      selection.ref.size = sizeOf<GhosttySelection>();
      startRef.ref.size = sizeOf<GhosttyGridRef>();
      endRef.ref.size = sizeOf<GhosttyGridRef>();
      final startResult = ghostty_tracked_grid_ref_snapshot(start, startRef);
      final endResult = ghostty_tracked_grid_ref_snapshot(end, endRef);
      if (startResult != GhosttyResult.GHOSTTY_SUCCESS ||
          endResult != GhosttyResult.GHOSTTY_SUCCESS) {
        calloc.free(selection);
        return null;
      }
      _copyGridRef(selection.ref.start, startRef.ref);
      _copyGridRef(selection.ref.end, endRef.ref);
      selection.ref.rectangle = false;
      return selection;
    } finally {
      calloc.free(endRef);
      calloc.free(startRef);
    }
  }

  bool _setTrackedSelectionFromSnapshot(GhosttySelection selection) {
    final nextStart = _trackGridRefSnapshot(selection.start);
    if (nextStart == null) return false;
    final nextEnd = _trackGridRefSnapshot(selection.end);
    if (nextEnd == null) {
      ghostty_tracked_grid_ref_free(nextStart);
      return false;
    }
    clearTrackedSelection();
    _selectionStartRef = nextStart;
    _selectionEndRef = nextEnd;
    return true;
  }

  GhosttyTrackedGridRef? _trackGridRefSnapshot(GhosttyGridRef ref) {
    final point = _pointFromGridRef(
      ref,
      GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN,
    );
    if (point == null) return null;
    return _trackPoint(GhosttyPointTag.GHOSTTY_POINT_TAG_SCREEN, point);
  }

  GhosttyTrackedGridRef? _trackPoint(
    GhosttyPointTag tag,
    TerminalCellPoint point,
  ) {
    final out = calloc<GhosttyTrackedGridRef>();
    final pointPtr = calloc<GhosttyPoint>();
    try {
      _setPoint(pointPtr.ref, tag, point);
      final result = ghostty_terminal_grid_ref_track(
        _terminal,
        pointPtr.ref,
        out,
      );
      if (result != GhosttyResult.GHOSTTY_SUCCESS || out.value.address == 0) {
        return null;
      }
      return out.value;
    } finally {
      calloc.free(pointPtr);
      calloc.free(out);
    }
  }

  bool _setTrackedPoint(
    GhosttyTrackedGridRef ref,
    GhosttyPointTag tag,
    TerminalCellPoint point,
  ) {
    final pointPtr = calloc<GhosttyPoint>();
    try {
      _setPoint(pointPtr.ref, tag, point);
      final result = ghostty_tracked_grid_ref_set(ref, _terminal, pointPtr.ref);
      return result == GhosttyResult.GHOSTTY_SUCCESS;
    } finally {
      calloc.free(pointPtr);
    }
  }

  bool _gridRefForPoint(
    GhosttyPointTag tag,
    TerminalCellPoint point,
    Pointer<GhosttyGridRef> outRef,
  ) {
    final pointPtr = calloc<GhosttyPoint>();
    try {
      outRef.ref.size = sizeOf<GhosttyGridRef>();
      _setPoint(pointPtr.ref, tag, point);
      final result = ghostty_terminal_grid_ref(_terminal, pointPtr.ref, outRef);
      return result == GhosttyResult.GHOSTTY_SUCCESS;
    } finally {
      calloc.free(pointPtr);
    }
  }

  TerminalCellPoint? _trackedPoint(
    GhosttyTrackedGridRef ref,
    GhosttyPointTag tag,
  ) {
    final out = calloc<GhosttyPointCoordinate>();
    try {
      final result = ghostty_tracked_grid_ref_point(ref, tag, out);
      if (result != GhosttyResult.GHOSTTY_SUCCESS) return null;
      return TerminalCellPoint(row: out.ref.y, col: out.ref.x);
    } finally {
      calloc.free(out);
    }
  }

  TerminalCellPoint? _pointFromGridRef(
    GhosttyGridRef ref,
    GhosttyPointTag tag,
  ) {
    final refPtr = calloc<GhosttyGridRef>();
    final out = calloc<GhosttyPointCoordinate>();
    try {
      _copyGridRef(refPtr.ref, ref);
      final result = ghostty_terminal_point_from_grid_ref(
        _terminal,
        refPtr,
        tag,
        out,
      );
      if (result != GhosttyResult.GHOSTTY_SUCCESS) return null;
      return TerminalCellPoint(row: out.ref.y, col: out.ref.x);
    } finally {
      calloc.free(out);
      calloc.free(refPtr);
    }
  }

  void _setPoint(GhosttyPoint point, GhosttyPointTag tag, TerminalCellPoint p) {
    point.tagAsInt = tag.value;
    point.value.coordinate.x = _clampInt(p.col, 0, 0xffff);
    point.value.coordinate.y = p.row < 0 ? 0 : p.row;
  }

  int _clampInt(int value, int min, int max) {
    if (max < min) return min;
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  void _copyGridRef(GhosttyGridRef target, GhosttyGridRef source) {
    target.size = sizeOf<GhosttyGridRef>();
    target.node = source.node;
    target.x = source.x;
    target.y = source.y;
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
      final textBytes = utf8.encode(text);
      if (textBytes.length > _keyTextBufCapacity) {
        calloc.free(_keyTextBuf);
        _keyTextBufCapacity = _nextBufferCapacity(textBytes.length);
        _keyTextBuf = calloc<Uint8>(_keyTextBufCapacity);
      }
      _keyTextBuf.asTypedList(textBytes.length).setAll(0, textBytes);
      ghostty_key_event_set_utf8(
        _keyEvent,
        _keyTextBuf.cast(),
        textBytes.length,
      );
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

  /// Sanitize and encode paste data using the terminal's live bracketed-paste
  /// mode. The C encoder also normalizes newlines when mode 2004 is disabled.
  void encodePasteAndWrite(Uint8List data) {
    if (data.isEmpty) return;
    if (data.length > _pasteInputCapacity) {
      calloc.free(_pasteInputBuf);
      _pasteInputCapacity = _nextBufferCapacity(data.length);
      _pasteInputBuf = calloc<Uint8>(_pasteInputCapacity);
    }
    final requiredOutput = data.length + 12;
    if (requiredOutput > _pasteOutputCapacity) {
      calloc.free(_pasteOutputBuf);
      _pasteOutputCapacity = _nextBufferCapacity(requiredOutput);
      _pasteOutputBuf = calloc<Uint8>(_pasteOutputCapacity);
    }
    _pasteInputBuf.asTypedList(data.length).setAll(0, data);
    _pasteBracketedPtr.value = false;
    final modeResult = ghostty_terminal_mode_get(
      _terminal,
      _bracketedPasteMode,
      _pasteBracketedPtr,
    );
    final bracketed =
        modeResult == GhosttyResult.GHOSTTY_SUCCESS && _pasteBracketedPtr.value;
    final result = ghostty_paste_encode(
      _pasteInputBuf.cast(),
      data.length,
      bracketed,
      _pasteOutputBuf.cast(),
      _pasteOutputCapacity,
      _keyLen,
    );
    if (result == GhosttyResult.GHOSTTY_SUCCESS && _keyLen.value > 0) {
      _writeOut(_pasteOutputBuf, _keyLen.value);
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

    _mousePositionPtr.ref.x = x;
    _mousePositionPtr.ref.y = y;
    ghostty_mouse_event_set_position(_mouseEvent, _mousePositionPtr.ref);

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
    _scrollViewportPtr.ref.tagAsInt =
        GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_DELTA.value;
    _scrollViewportPtr.ref.value.delta = delta;
    ghostty_terminal_scroll_viewport(_terminal, _scrollViewportPtr.ref);
  }

  void scrollToBottom() {
    _scrollViewportPtr.ref.tagAsInt =
        GhosttyTerminalScrollViewportTag.GHOSTTY_SCROLL_VIEWPORT_BOTTOM.value;
    ghostty_terminal_scroll_viewport(_terminal, _scrollViewportPtr.ref);
  }

  void scrollToOffset(int offset) {
    final metrics = scrollbarMetrics;
    final maxOffset = metrics.total > metrics.length
        ? metrics.total - metrics.length
        : 0;
    final target = offset.clamp(0, maxOffset).toInt();
    final delta = target - metrics.offset;
    if (delta != 0) scroll(delta);
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
    _mouseEncoderSizePtr.ref.size = sizeOf<GhosttyMouseEncoderSize>();
    _mouseEncoderSizePtr.ref.screen_width = screenWidth;
    _mouseEncoderSizePtr.ref.screen_height = screenHeight;
    _mouseEncoderSizePtr.ref.cell_width = cellWidth;
    _mouseEncoderSizePtr.ref.cell_height = cellHeight;
    _mouseEncoderSizePtr.ref.padding_left = paddingLeft;
    _mouseEncoderSizePtr.ref.padding_top = paddingTop;
    _mouseEncoderSizePtr.ref.padding_right = 0;
    _mouseEncoderSizePtr.ref.padding_bottom = 0;
    ghostty_mouse_encoder_setopt(
      _mouseEncoder,
      GhosttyMouseEncoderOption.GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
      _mouseEncoderSizePtr.cast(),
    );
  }

  // Cache palette
  late final Pointer<GhosttyColorRgb> _palettePtr = calloc<GhosttyColorRgb>(
    256,
  );
  bool _paletteDirty = true;

  int _nextBufferCapacity(int required) {
    var capacity = 64;
    while (capacity < required) {
      capacity *= 2;
    }
    return capacity;
  }

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

  TerminalFrameEncodingResult encodeFrame({
    required int frameId,
    required int baseFrameId,
    required bool full,
    required TerminalFrameMetadata metadata,
  }) {
    final encoder = TerminalFrameEncoder(
      frameId: frameId,
      baseFrameId: baseFrameId,
      full: full,
      metadata: metadata,
    );
    populateRowIterator();
    var rowIndex = 0;
    while (rowIteratorNext()) {
      final rowResult = ghostty_render_state_row_get_multi(
        _rowIteratorPtr.value,
        2,
        _rowGetKeys,
        _rowGetValues,
        _multiWrittenPtr,
      );
      if (rowResult != GhosttyResult.GHOSTTY_SUCCESS) {
        throw StateError('failed to read terminal row: $rowResult');
      }
      if (!full && !_rowDirtyPtr.value) {
        rowIndex++;
        continue;
      }

      final encodedRow = encoder.startRow(rowIndex);
      var colIndex = 0;
      while (rowCellsNext()) {
        _readCurrentCellIntoScratch();
        final wide = GhosttyCellWide.fromValue(_cellWidePtr.value);
        if (wide == GhosttyCellWide.GHOSTTY_CELL_WIDE_SPACER_TAIL) {
          colIndex++;
          continue;
        }

        final style = _stylePtr.ref;
        var foreground = _resolveSnapshotColor(
          style.fg_color,
          metadata.foregroundArgb,
        );
        var background = _resolveSnapshotColor(
          style.bg_color,
          metadata.backgroundArgb,
        );
        if (style.inverse) {
          final swap = foreground;
          foreground = background;
          background = swap;
        }
        if (style.faint) foreground = _withAlpha(foreground, 0x80);
        final drawsBackground = background != metadata.backgroundArgb;
        final textLength = _cellUtf8BufferPtr.ref.len;
        if (textLength > 0 || drawsBackground) {
          encodedRow.addCell(
            col: colIndex,
            widthCells: wide == GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE ? 2 : 1,
            textBytes: _cellUtf8Bytes.asTypedList(textLength),
            foregroundArgb: foreground,
            backgroundArgb: background,
            drawsBackground: drawsBackground,
            bold: style.bold,
            italic: style.italic,
            invisible: style.invisible,
          );
        }
        colIndex++;
      }
      encodedRow.finish();
      setRowDirty(false);
      rowIndex++;
    }
    if (rowIndex != rows) {
      throw StateError('terminal frame row count changed during encoding');
    }
    setDirty(GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE);
    return encoder.finish(metadata.viewportOffset);
  }

  void _readCurrentCellIntoScratch() {
    while (true) {
      _stylePtr.ref.size = sizeOf<GhosttyStyle>();
      _cellUtf8BufferPtr.ref.len = 0;
      final result = ghostty_render_state_row_cells_get_multi(
        _rowCellsPtr.value,
        3,
        _cellGetKeys,
        _cellGetValues,
        _multiWrittenPtr,
      );
      if (result == GhosttyResult.GHOSTTY_SUCCESS) break;
      if (result != GhosttyResult.GHOSTTY_OUT_OF_SPACE) {
        throw StateError('failed to read terminal cell: $result');
      }
      final required = _cellUtf8BufferPtr.ref.len;
      if (required <= _cellUtf8Capacity) {
        throw StateError('invalid terminal grapheme buffer size: $required');
      }
      calloc.free(_cellUtf8Bytes);
      _cellUtf8Capacity = required;
      _cellUtf8Bytes = calloc<Uint8>(_cellUtf8Capacity);
      _cellUtf8BufferPtr.ref
        ..ptr = _cellUtf8Bytes
        ..cap = _cellUtf8Capacity;
    }
    final wideResult = ghostty_cell_get(
      _cellPtr.value,
      GhosttyCellData.GHOSTTY_CELL_DATA_WIDE,
      _cellWidePtr.cast(),
    );
    if (wideResult != GhosttyResult.GHOSTTY_SUCCESS) {
      throw StateError('failed to read terminal cell width: $wideResult');
    }
  }

  TerminalSnapshot snapshot({
    required int defaultForegroundArgb,
    required int defaultBackgroundArgb,
    TerminalSelection? selection,
  }) {
    final cursor = readCursorState();
    final metadata = captureFrameMetadata(
      defaultForegroundArgb: defaultForegroundArgb,
      defaultBackgroundArgb: defaultBackgroundArgb,
      cursor: cursor,
      selection: selection,
    );
    final encoded = encodeFrame(
      frameId: 1,
      baseFrameId: 0,
      full: true,
      metadata: metadata,
    );
    return TerminalFrameUpdate.decode(encoded.bytes).applyTo(null);
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
    onHostWrite(data);
  }
}
