// ignore_for_file: invalid_use_of_protected_member

part of '../motif_terminal_view.dart';

extension _MotifTerminalCore on _MotifTerminalViewState {
  void _onHostWrite(Uint8List bytes) {
    _lastHostWriteAt = DateTime.now();
    _flushRemoteBytesToWorker();
    widget.motif.writePty(widget.ptyId, bytes);
  }

  void _onRemoteBytes(Uint8List bytes) {
    _remoteChunks++;
    _remoteBytes += bytes.length;
    final logAtInfo = _remoteChunks <= 3 || _remoteChunks == 10;
    final logAtDebug = _remoteChunks == 100 || _remoteChunks % 1000 == 0;
    if (logAtInfo || logAtDebug) {
      final message =
          'terminal bytes pty=${widget.ptyId} chunk=$_remoteChunks '
          'bytes=${bytes.length} totalBytes=$_remoteBytes '
          'initialized=$_initialized '
          'queuedChunks=${_remoteByteBatcher.pendingChunks} '
          'queuedBytes=${_remoteByteBatcher.pendingBytes}';
      if (logAtInfo) {
        Log.i(message, name: 'motif.terminal');
      } else {
        Log.d(message, name: 'motif.terminal');
      }
    }
    // While a failed worker is being rebuilt, PtyOutputHub's bounded ring is
    // the owner of recent output. Do not create a second unbounded staging
    // queue in the terminal State.
    if (_terminalError != null) return;
    _enqueueRemoteBytes(bytes);
    _scheduleRemoteBytesFlush(bytes.length);
  }

  void _enqueueRemoteBytes(Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (_remoteByteBatcher.add(bytes)) return;
    final error = TerminalWorkerBacklogOverflow(
      pendingBytes: _remoteByteBatcher.pendingBytes + bytes.length,
      limitBytes: _remoteByteBatcher.maxPendingBytes,
    );
    _workerNeedsColdResync = true;
    _remoteByteBatcher.clear();
    _failTerminal(error, StackTrace.current);
  }

  void _flushRemoteBytesToWorker() {
    _remoteByteFlushTimer?.cancel();
    _remoteByteFlushTimer = null;
    final worker = _worker;
    if (!_initialized || _terminalError != null || worker == null) return;
    for (final batch in _remoteByteBatcher.drain()) {
      worker.feedBytes(batch);
    }
  }

  void _scheduleRemoteBytesFlush(int newestChunkBytes) {
    if (!_initialized || _terminalError != null || _worker == null) return;
    final lastWrite = _lastHostWriteAt;
    final interactive =
        lastWrite != null &&
        DateTime.now().difference(lastWrite) <=
            _MotifTerminalViewState._interactiveEchoWindow;
    if (interactive ||
        newestChunkBytes >= _remoteByteBatcher.maxBatchBytes ||
        _remoteByteBatcher.pendingBytes >= _remoteByteBatcher.maxBatchBytes) {
      _flushRemoteBytesToWorker();
      return;
    }
    _remoteByteFlushTimer ??= Timer(
      _MotifTerminalViewState._remoteByteCoalesceDelay,
      _flushRemoteBytesToWorker,
    );
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

  void _scheduleTerminalInit(BoxConstraints constraints) {
    if (_initialized || _workerStarting || _terminalError != null) return;
    _pendingInitConstraints = constraints;
    if (_terminalInitTimer != null) return;
    _terminalInitTimer = Timer(_MotifTerminalViewState._terminalInitDelay, () {
      _terminalInitTimer = null;
      if (!mounted || _initialized || _terminalError != null) return;
      final pending = _pendingInitConstraints;
      if (pending == null) return;
      _initTerminal(pending);
      if (mounted) setState(() {});
    });
  }

  void _initTerminal(BoxConstraints constraints) {
    if (_initialized || _workerStarting || _terminalError != null) return;
    try {
      _cols = ((constraints.maxWidth - 2 * widget.padding) / _cellWidth)
          .floor()
          .clamp(1, 1000);
      _rows = ((constraints.maxHeight - 2 * widget.padding) / _cellHeight)
          .floor()
          .clamp(1, 1000);
      Log.i(
        'terminal worker starting pty=${widget.ptyId} cols=$_cols rows=$_rows '
        'constraints=${constraints.maxWidth.toStringAsFixed(1)}x'
        '${constraints.maxHeight.toStringAsFixed(1)} '
        'cell=${_cellWidth.toStringAsFixed(1)}x'
        '${_cellHeight.toStringAsFixed(1)} '
        'queuedChunks=${_remoteByteBatcher.pendingChunks} '
        'queuedBytes=${_remoteByteBatcher.pendingBytes}',
        name: 'motif.terminal',
      );
      _workerStarting = true;
      final generation = ++_workerGeneration;
      unawaited(_startWorker(generation, constraints));
    } catch (e, st) {
      _terminalError = e;
      _terminalStack = st;
      _initialized = false;
      _workerStarting = false;
      _resizeTimer?.cancel();
      _scheduleTerminalRetry();
      if (mounted) setState(() {});
    }
  }

  Future<void> _startWorker(int generation, BoxConstraints constraints) async {
    try {
      final worker = await TerminalWorkerClient.spawn(
        onHostWrite: _onHostWrite,
        onSnapshot: (snapshot, acknowledge) =>
            _onWorkerSnapshot(generation, snapshot, acknowledge),
        onInitialized: () => _onWorkerInitialized(generation),
        onError: (error) => _onWorkerError(generation, error),
      );
      if (!_isCurrentWorker(generation)) {
        await worker.dispose();
        return;
      }
      _worker = worker;
      worker.init(
        cols: _cols,
        rows: _rows,
        screenWidth: constraints.maxWidth.toInt(),
        screenHeight: constraints.maxHeight.toInt(),
        cellWidth: _cellWidth.toInt(),
        cellHeight: _cellHeight.toInt(),
        paddingLeft: widget.padding.toInt(),
        paddingTop: widget.padding.toInt(),
        foregroundArgb: _colorToArgb(widget.palette.foreground),
        backgroundArgb: _colorToArgb(widget.palette.background),
        waitForFirstFeed: true,
        initialSnapshotFallback: _snapshot == null
            ? const Duration(milliseconds: 100)
            : null,
      );
    } catch (e, st) {
      if (_isCurrentWorker(generation)) _failTerminal(e, st);
    }
  }

  _CursorSnapshot _readCursorSnapshot() {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const _CursorSnapshot(
        visible: false,
        inViewport: false,
        x: -1,
        y: -1,
        widthCells: 1,
        style: GhosttyRenderStateCursorVisualStyle
            .GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK,
      );
    }
    final cursorSpan = snapshot.cursorCellSpan;
    return _CursorSnapshot(
      visible: snapshot.cursorVisible,
      inViewport: snapshot.cursorInViewport,
      x: cursorSpan.col,
      y: snapshot.cursorY,
      widthCells: cursorSpan.widthCells,
      style: GhosttyRenderStateCursorVisualStyle.fromValue(
        snapshot.cursorStyle,
      ),
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
      _resetSmoothScroll(clearRows: true);
      _discardTerminalSelectionState();
      _worker?.resize(
        cols: _cols,
        rows: _rows,
        screenWidth: constraints.maxWidth.toInt(),
        screenHeight: constraints.maxHeight.toInt(),
        cellWidth: _cellWidth.toInt(),
        cellHeight: _cellHeight.toInt(),
        paddingLeft: widget.padding.toInt(),
        paddingTop: widget.padding.toInt(),
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

  bool _isCurrentWorker(int generation) =>
      mounted && generation == _workerGeneration && _terminalError == null;

  void _onWorkerInitialized(int generation) {
    if (!_isCurrentWorker(generation)) return;
    _workerStarting = false;
    _initialized = true;
    if (_workerNeedsColdResync) {
      _workerNeedsColdResync = false;
      _remoteByteBatcher.clear();
      unawaited(_coldResyncAfterWorkerStart(generation));
    } else {
      _flushRemoteBytesToWorker();
    }
    _scheduleResizeAndMaybeOpen();
    _syncKeyboardLift();
    if (mounted) setState(() {});
    _scheduleTerminalScrollPositionSync();
  }

  void _onWorkerSnapshot(
    int generation,
    TerminalSnapshot snapshot,
    void Function() acknowledge,
  ) {
    if (!_isCurrentWorker(generation)) {
      acknowledge();
      return;
    }
    // Isolate messages are not synchronized to Flutter's vsync. Apply the
    // frame at the next vsync boundary, then acknowledge it so the worker can
    // build at most one successor from all output accumulated in the meantime.
    _pendingFrameSnapshot?.acknowledge();
    _pendingFrameSnapshot = (
      generation: generation,
      snapshot: snapshot,
      acknowledge: acknowledge,
    );
    if (_snapshotFrameScheduled) return;
    _snapshotFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _snapshotFrameScheduled = false;
      final pending = _pendingFrameSnapshot;
      _pendingFrameSnapshot = null;
      if (pending == null) return;
      try {
        _applyWorkerSnapshot(pending.generation, pending.snapshot);
      } finally {
        pending.acknowledge();
      }
    });
  }

  void _applyWorkerSnapshot(int generation, TerminalSnapshot snapshot) {
    if (!_isCurrentWorker(generation)) return;
    final previousSnapshot = _snapshot;
    final wasFollowingLatest =
        previousSnapshot != null &&
        _smoothScrollPosition.initialized &&
        (_smoothScrollPosition.viewportOffset -
                    previousSnapshot.maxViewportOffset)
                .abs() <=
            0.0001 &&
        snapshot.isAtLatest;
    if (snapshot.alternateScreenActive || snapshot.mouseTrackingActive) {
      _resetSmoothScroll(clearRows: true);
    } else {
      if (wasFollowingLatest) _scrollRowCache.clear();
      _smoothScrollPosition.synchronize(
        viewportOffset: snapshot.viewportOffset,
        maxOffset: snapshot.maxViewportOffset,
        followLatest: wasFollowingLatest,
      );
      _scrollRowCache.ingest(snapshot);
    }
    final viewportChanged =
        previousSnapshot?.viewportOffset != snapshot.viewportOffset;
    final selectionChanged = _selection != snapshot.selection;
    _snapshot = snapshot;
    _selection = snapshot.selection;
    _scrollbarVisibility.updateCanShow(
      snapshot.hasScrollback && !snapshot.alternateScreenActive,
    );
    if (snapshot.isAtLatest || snapshot.alternateScreenActive) {
      _scrollbarVisibility.setReturnButtonHovered(false);
    }
    final cursorSnapshot = _readCursorSnapshot();
    final cursorChanged = cursorSnapshot != _lastCursorSnapshot;
    _lastCursorSnapshot = cursorSnapshot;
    _prefetchMissingSmoothScrollRows(snapshot);
    if (cursorChanged) {
      _syncKeyboardLift();
      _scheduleImeRectSync();
    }
    if (selectionChanged || (viewportChanged && _selection != null)) {
      if (_canShowTouchSelectionOverlays) {
        _showTouchSelectionHandles();
        if (!_touchSelectionGestureActive &&
            _touchSelectionDragHandle == null) {
          _showTouchSelectionMenu();
        } else {
          _touchSelectionMenuEntry?.markNeedsBuild();
        }
      } else {
        _hideTouchSelectionHandles();
        _hideTouchSelectionMenu();
      }
    }
    if (mounted) setState(() {});
    _scheduleTerminalScrollPositionSync();
  }

  void _onWorkerError(int generation, Object error) {
    if (!_isCurrentWorker(generation)) return;
    if (error is TerminalWorkerBacklogOverflow) {
      _workerNeedsColdResync = true;
      _remoteByteBatcher.clear();
    }
    _failTerminal(error, StackTrace.current);
  }

  Future<void> _coldResyncAfterWorkerStart(int generation) async {
    try {
      await widget.motif.resyncPtyStream(
        widget.ptyId,
        reason: 'terminal worker backlog overflow',
      );
    } catch (error, stackTrace) {
      if (_isCurrentWorker(generation)) {
        _failTerminal(error, stackTrace);
      }
    }
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
    _terminalInitTimer?.cancel();
    final worker = _worker;
    _worker = null;
    _pendingFrameSnapshot?.acknowledge();
    _pendingFrameSnapshot = null;
    if (worker != null) unawaited(worker.dispose());
    _initialized = false;
    _workerStarting = false;
    _resetSmoothScroll(clearRows: true);
    _discardTerminalSelectionState();
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
      _scheduleResizeAndMaybeOpen();
    } else {
      final pending = _pendingInitConstraints;
      if (pending != null) _initTerminal(pending);
    }
  }

  void _restartWorkerForNewPty() {
    _terminalInitTimer?.cancel();
    _terminalInitTimer = null;
    _resizeTimer?.cancel();
    _resizeTimer = null;
    _workerGeneration++;
    final worker = _worker;
    _worker = null;
    if (worker != null) unawaited(worker.dispose());
    _initialized = false;
    _workerStarting = false;
    _workerNeedsColdResync = false;
    _snapshot = null;
    _resetSmoothScroll(clearRows: true);
    _pendingFrameSnapshot?.acknowledge();
    _pendingFrameSnapshot = null;
    _discardTerminalSelectionState();
    _terminalRenderCache.clear();
    _lastCursorSnapshot = null;
    _remoteByteFlushTimer?.cancel();
    _remoteByteFlushTimer = null;
    _remoteByteBatcher.clear();
    _terminalError = null;
    _terminalStack = null;
  }

  int _colorToArgb(Color color) => color.toARGB32();
}
