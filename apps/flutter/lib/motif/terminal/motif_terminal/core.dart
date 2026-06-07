// ignore_for_file: invalid_use_of_protected_member

part of '../motif_terminal_view.dart';

extension _MotifTerminalCore on _MotifTerminalViewState {
  void _onHostWrite(Uint8List bytes) {
    widget.motif.writePty(widget.ptyId, bytes);
  }

  void _onRemoteBytes(Uint8List bytes) {
    _remoteChunks++;
    _remoteBytes += bytes.length;
    if (_remoteChunks <= 3 || _remoteChunks == 10 || _remoteChunks % 100 == 0) {
      Log.i(
        'terminal bytes pty=${widget.ptyId} chunk=$_remoteChunks '
        'bytes=${bytes.length} totalBytes=$_remoteBytes '
        'initialized=$_initialized queuedChunks=${_remoteByteQueue.length} '
        'queuedBytes=$_remoteByteQueueBytes',
        name: 'motif.terminal',
      );
    }
    _enqueueRemoteBytes(bytes);
  }

  void _enqueueRemoteBytes(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _remoteByteQueue.add(Uint8List.fromList(bytes));
    _remoteByteQueueBytes += bytes.length;
  }

  bool _drainRemoteBytesForFrame() {
    if (!_initialized ||
        _terminalError != null ||
        _remoteByteQueue.isEmpty ||
        _remoteByteQueueBytes <= 0) {
      return false;
    }

    var fedBytes = 0;
    final sw = Stopwatch()..start();
    while (_remoteByteQueue.isNotEmpty &&
        fedBytes < _MotifTerminalViewState._remoteFeedMaxBytesPerFrame) {
      final chunk = _remoteByteQueue.first;
      final remaining = chunk.length - _remoteByteQueueOffset;
      if (remaining <= 0) {
        _remoteByteQueue.removeFirst();
        _remoteByteQueueOffset = 0;
        continue;
      }

      final byteBudget =
          _MotifTerminalViewState._remoteFeedMaxBytesPerFrame - fedBytes;
      final take = remaining <= byteBudget ? remaining : byteBudget;
      final start = _remoteByteQueueOffset;
      final end = start + take;
      final slice = start == 0 && end == chunk.length
          ? chunk
          : Uint8List.sublistView(chunk, start, end);
      _state.feedBytes(slice);

      fedBytes += take;
      _remoteByteQueueBytes -= take;
      _remoteByteQueueOffset = end;
      if (_remoteByteQueueOffset >= chunk.length) {
        _remoteByteQueue.removeFirst();
        _remoteByteQueueOffset = 0;
      }
      if (sw.elapsedMicroseconds >=
          _MotifTerminalViewState._remoteFeedMaxMicrosPerFrame) {
        break;
      }
    }

    if (_remoteByteQueue.isEmpty) {
      _remoteByteQueueBytes = 0;
      _remoteByteQueueOffset = 0;
    }
    if (fedBytes > 0 &&
        (_remoteByteQueue.isNotEmpty ||
            _remoteChunks <= 3 ||
            _remoteChunks == 10 ||
            _remoteChunks % 100 == 0)) {
      Log.i(
        'terminal feed pty=${widget.ptyId} fedBytes=$fedBytes '
        'queuedChunks=${_remoteByteQueue.length} '
        'queuedBytes=$_remoteByteQueueBytes',
        name: 'motif.terminal',
      );
    }
    return fedBytes > 0;
  }

  void _measureCell() {
    final font = _fontSpec;
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: font.family,
              fontSize: widget.fontSize,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              fontFamily: font.family,
              fontFamilyFallback: font.fallback,
              fontSize: widget.fontSize,
            ),
          )
          ..addText('M');
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    _cellWidth = paragraph.maxIntrinsicWidth;
    _cellHeight = paragraph.height;
  }

  void _initTerminal(BoxConstraints constraints) {
    if (_initialized || _terminalError != null) return;
    try {
      _initialized = true;
      _cols = ((constraints.maxWidth - 2 * widget.padding) / _cellWidth)
          .floor()
          .clamp(1, 1000);
      _rows = ((constraints.maxHeight - 2 * widget.padding) / _cellHeight)
          .floor()
          .clamp(1, 1000);
      _state.init(_cols, _rows);
      _state.setMouseEncoderSize(
        constraints.maxWidth.toInt(),
        constraints.maxHeight.toInt(),
        _cellWidth.toInt(),
        _cellHeight.toInt(),
        widget.padding.toInt(),
        widget.padding.toInt(),
      );
      Log.i(
        'terminal initialized pty=${widget.ptyId} cols=$_cols rows=$_rows '
        'constraints=${constraints.maxWidth.toStringAsFixed(1)}x'
        '${constraints.maxHeight.toStringAsFixed(1)} '
        'cell=${_cellWidth.toStringAsFixed(1)}x'
        '${_cellHeight.toStringAsFixed(1)} '
        'queuedChunks=${_remoteByteQueue.length} '
        'queuedBytes=$_remoteByteQueueBytes',
        name: 'motif.terminal',
      );
      _scheduleResizeAndMaybeOpen();
      _startFrameTimer();
    } catch (e, st) {
      _terminalError = e;
      _terminalStack = st;
      _initialized = false;
      _resizeTimer?.cancel();
      _frameTimer?.cancel();
      _scheduleTerminalRetry();
      // Runs inside LayoutBuilder's build, so defer the rebuild that swaps in
      // the error view.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _startFrameTimer() {
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final fedRemoteBytes = _drainRemoteBytesForFrame();
      _state.updateRenderState();
      final dirty = _state.getDirty();
      final cursorSnapshot = _readCursorSnapshot();
      final cursorChanged = cursorSnapshot != _lastCursorSnapshot;
      _lastCursorSnapshot = cursorSnapshot;
      if (cursorChanged) {
        _syncKeyboardLift();
        _scheduleImeRectSync();
      }
      if (dirty != GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE ||
          fedRemoteBytes ||
          cursorChanged) {
        if (mounted) setState(() {});
      }
    });
  }

  _CursorSnapshot _readCursorSnapshot() {
    final visible = _state.cursorVisible;
    final inViewport = _state.cursorInViewport;
    return _CursorSnapshot(
      visible: visible,
      inViewport: inViewport,
      x: inViewport ? _state.cursorX : -1,
      y: inViewport ? _state.cursorY : -1,
      style: _state.cursorStyle,
    );
  }

  void _handleResize(BoxConstraints constraints) {
    if (!_initialized || _terminalError != null) return;
    final newCols = ((constraints.maxWidth - 2 * widget.padding) / _cellWidth)
        .floor();
    final newRows = ((constraints.maxHeight - 2 * widget.padding) / _cellHeight)
        .floor();
    if (newCols > 0 && newRows > 0 && (newCols != _cols || newRows != _rows)) {
      _cols = newCols;
      _rows = newRows;
      _state.resize(_cols, _rows, _cellWidth.toInt(), _cellHeight.toInt());
      _state.setMouseEncoderSize(
        constraints.maxWidth.toInt(),
        constraints.maxHeight.toInt(),
        _cellWidth.toInt(),
        _cellHeight.toInt(),
        widget.padding.toInt(),
        widget.padding.toInt(),
      );
      _scheduleResizeAndMaybeOpen();
      _scheduleImeRectSync();
    }
  }

  void _scheduleResizeAndMaybeOpen() {
    if (!_initialized || _terminalError != null) return;
    _pendingResizeCols = _cols;
    _pendingResizeRows = _rows;
    final generation = _streamGeneration;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 50), () {
      _resizeTimer = null;
      unawaited(_flushResizeAndMaybeOpen(generation));
    });
  }

  void _invalidateStreamWork() {
    _streamGeneration++;
    _resizeTimer?.cancel();
    _resizeTimer = null;
  }

  bool _isCurrentStreamWork(int generation) {
    return mounted &&
        _initialized &&
        _terminalError == null &&
        generation == _streamGeneration;
  }

  Future<void> _flushResizeAndMaybeOpen(int generation) async {
    final cols = _pendingResizeCols;
    final rows = _pendingResizeRows;
    if (cols == null || rows == null) return;
    try {
      if (!_isCurrentStreamWork(generation)) return;
      Log.i(
        'terminal resize pty=${widget.ptyId} cols=$cols rows=$rows '
        'active=${widget.active} gen=$generation',
        name: 'motif.terminal',
      );
      await widget.motif.resizePty(widget.ptyId, cols, rows);
      _terminalRetryAttempt = 0;
      if (!_isCurrentStreamWork(generation) || !widget.active) return;
      Log.i(
        'terminal activate stream pty=${widget.ptyId} gen=$generation',
        name: 'motif.terminal',
      );
      await widget.motif.activatePtyStream(widget.ptyId);
      Log.i(
        'terminal stream active pty=${widget.ptyId} gen=$generation',
        name: 'motif.terminal',
      );
    } catch (e, st) {
      if (_isCurrentStreamWork(generation)) {
        _failTerminal(e, st);
      } else {
        // Superseded work — don't fail the terminal, but don't swallow either.
        Log.d(
          'pty ${widget.ptyId}: stale resize/activate failed',
          name: 'motif.terminal',
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  void _failTerminal(Object error, StackTrace stackTrace) {
    if (_terminalError != null) return;
    _terminalError = error;
    _terminalStack = stackTrace;
    _resizeTimer?.cancel();
    _frameTimer?.cancel();
    _scheduleTerminalRetry();
    if (mounted) setState(() {});
  }

  /// Schedule an automatic recovery attempt with exponential backoff
  /// (1s, 2s, 4s, 8s, then every 16s). Most failures here are transient RPC
  /// errors (reconnect, timeout), so the terminal should heal on its own.
  void _scheduleTerminalRetry() {
    _retryTimer?.cancel();
    final delay = Duration(seconds: 1 << _terminalRetryAttempt.clamp(0, 4));
    _terminalRetryAttempt++;
    Log.i(
      'terminal retry scheduled pty=${widget.ptyId} '
      'attempt=$_terminalRetryAttempt delay=${delay.inSeconds}s',
      name: 'motif.terminal',
    );
    _retryTimer = Timer(delay, _retryTerminal);
  }

  /// Clear the failure and try again. If init never succeeded, the rebuild
  /// re-runs [_initTerminal] via LayoutBuilder; otherwise resume the frame
  /// timer and re-issue resize/activate for the current pty.
  void _retryTerminal() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!mounted || _terminalError == null) return;
    Log.i(
      'terminal retry pty=${widget.ptyId} attempt=$_terminalRetryAttempt '
      'initialized=$_initialized',
      name: 'motif.terminal',
    );
    setState(() {
      _terminalError = null;
      _terminalStack = null;
    });
    if (_initialized) {
      _startFrameTimer();
      _scheduleResizeAndMaybeOpen();
    }
  }
}
