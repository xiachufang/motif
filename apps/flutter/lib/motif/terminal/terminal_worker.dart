import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import '../log/log.dart';
import 'ghostty_bindings.g.dart';
import 'terminal_frame_pacing.dart';
import 'terminal_snapshot.dart';
import 'terminal_state.dart';

typedef TerminalWorkerBytesCallback = void Function(Uint8List bytes);
typedef TerminalWorkerSnapshotCallback =
    void Function(TerminalSnapshot snapshot, void Function() acknowledge);
typedef TerminalWorkerErrorCallback = void Function(Object error);

class TerminalWorkerBacklogOverflow implements Exception {
  const TerminalWorkerBacklogOverflow({
    required this.pendingBytes,
    required this.limitBytes,
  });

  final int pendingBytes;
  final int limitBytes;

  @override
  String toString() =>
      'terminal worker backlog overflow: $pendingBytes > $limitBytes bytes';
}

class _QueuedWorkerCommand {
  const _QueuedWorkerCommand.message(this.message) : feedBytes = null;

  const _QueuedWorkerCommand.feed(this.message, this.feedBytes);

  final Map<String, Object?> message;
  final Uint8List? feedBytes;
}

class TerminalWorkerClient {
  TerminalWorkerClient._(
    this._isolate,
    this._events,
    this._eventStream,
    this._commands,
    this._onHostWrite,
    this._onSnapshot,
    this._onInitialized,
    this._onError,
    this._maxPendingFeedBytes,
    this._maxPendingCommandCount,
  ) {
    _eventsSub = _eventStream.listen(_handleEvent);
  }

  final Isolate _isolate;
  final ReceivePort _events;
  final Stream<Object?> _eventStream;
  final SendPort _commands;
  final TerminalWorkerBytesCallback _onHostWrite;
  final TerminalWorkerSnapshotCallback _onSnapshot;
  final void Function() _onInitialized;
  final TerminalWorkerErrorCallback _onError;
  final int _maxPendingFeedBytes;
  final int _maxPendingCommandCount;
  late final StreamSubscription<Object?> _eventsSub;
  bool _disposed = false;
  bool _commandInFlight = false;
  bool _backlogFailed = false;
  int _pendingFeedBytes = 0;
  final Queue<_QueuedWorkerCommand> _commandQueue =
      Queue<_QueuedWorkerCommand>();
  int _nextCopyRequestId = 1;
  final Map<int, Completer<String?>> _copySelectionRequests =
      <int, Completer<String?>>{};
  TerminalSnapshot? _lastSnapshot;

  static Future<TerminalWorkerClient> spawn({
    required TerminalWorkerBytesCallback onHostWrite,
    required TerminalWorkerSnapshotCallback onSnapshot,
    required void Function() onInitialized,
    required TerminalWorkerErrorCallback onError,
    int maxPendingFeedBytes = 4 * 1024 * 1024,
    int maxPendingCommandCount = 1024,
  }) async {
    assert(maxPendingFeedBytes > 0);
    assert(maxPendingCommandCount > 0);
    final events = ReceivePort();
    final eventStream = events.asBroadcastStream();
    final ready = Completer<SendPort>();
    late final StreamSubscription<Object?> readySub;
    readySub = eventStream.listen((message) {
      if (message case {'type': 'ready', 'port': final SendPort port}) {
        ready.complete(port);
      }
    });
    final isolate = await Isolate.spawn(
      _terminalWorkerMain,
      events.sendPort,
      debugName: 'MotifTerminalWorker',
    );
    final commands = await ready.future;
    await readySub.cancel();
    return TerminalWorkerClient._(
      isolate,
      events,
      eventStream,
      commands,
      onHostWrite,
      onSnapshot,
      onInitialized,
      onError,
      maxPendingFeedBytes,
      maxPendingCommandCount,
    );
  }

  void init({
    required int cols,
    required int rows,
    required int screenWidth,
    required int screenHeight,
    required int cellWidth,
    required int cellHeight,
    required int paddingLeft,
    required int paddingTop,
    required int foregroundArgb,
    required int backgroundArgb,
    bool waitForFirstFeed = false,
    Duration? initialSnapshotFallback,
  }) {
    _send({
      'type': 'init',
      'cols': cols,
      'rows': rows,
      'screenWidth': screenWidth,
      'screenHeight': screenHeight,
      'cellWidth': cellWidth,
      'cellHeight': cellHeight,
      'paddingLeft': paddingLeft,
      'paddingTop': paddingTop,
      'foregroundArgb': foregroundArgb,
      'backgroundArgb': backgroundArgb,
      'waitForFirstFeed': waitForFirstFeed,
      'initialSnapshotFallbackMs': initialSnapshotFallback?.inMilliseconds,
    });
  }

  void setThemeColors({
    required int foregroundArgb,
    required int backgroundArgb,
  }) {
    _send({
      'type': 'theme',
      'foregroundArgb': foregroundArgb,
      'backgroundArgb': backgroundArgb,
    });
  }

  void feedBytes(Uint8List bytes) {
    if (_disposed || _backlogFailed || bytes.isEmpty) return;
    final nextPending = _pendingFeedBytes + bytes.length;
    if (nextPending > _maxPendingFeedBytes) {
      _failBacklog(
        TerminalWorkerBacklogOverflow(
          pendingBytes: nextPending,
          limitBytes: _maxPendingFeedBytes,
        ),
      );
      return;
    }
    final owned = Uint8List.fromList(bytes);
    _pendingFeedBytes = nextPending;
    _enqueue(
      _QueuedWorkerCommand.feed({
        'type': 'feed',
        'enqueuedAtUs': DateTime.now().microsecondsSinceEpoch,
      }, owned),
    );
  }

  void resize({
    required int cols,
    required int rows,
    required int screenWidth,
    required int screenHeight,
    required int cellWidth,
    required int cellHeight,
    required int paddingLeft,
    required int paddingTop,
  }) {
    _send({
      'type': 'resize',
      'cols': cols,
      'rows': rows,
      'screenWidth': screenWidth,
      'screenHeight': screenHeight,
      'cellWidth': cellWidth,
      'cellHeight': cellHeight,
      'paddingLeft': paddingLeft,
      'paddingTop': paddingTop,
    });
  }

  void writeBytes(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _send({
      'type': 'writeBytes',
      'bytes': TransferableTypedData.fromList([bytes]),
    });
  }

  void encodePaste(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _send({
      'type': 'paste',
      'bytes': TransferableTypedData.fromList([bytes]),
    });
  }

  void encodeKey({
    required GhosttyKey key,
    required GhosttyKeyAction action,
    required int mods,
    required String? text,
    required int unshiftedCodepoint,
  }) {
    _send({
      'type': 'key',
      'key': key.value,
      'action': action.value,
      'mods': mods,
      'text': text,
      'unshiftedCodepoint': unshiftedCodepoint,
    });
  }

  void encodeMouse({
    required GhosttyMouseAction action,
    required GhosttyMouseButton button,
    required int mods,
    required double x,
    required double y,
  }) {
    _send({
      'type': 'mouse',
      'action': action.value,
      'button': button.value,
      'mods': mods,
      'x': x,
      'y': y,
    });
  }

  void encodeFocus(bool gained) {
    _send({'type': 'focus', 'gained': gained});
  }

  void scroll(int rows) {
    if (rows == 0) return;
    _send({'type': 'scroll', 'rows': rows});
  }

  void scrollToBottom() {
    _send({'type': 'scrollToBottom'});
  }

  void scrollToOffset(int offset) {
    _send({'type': 'scrollToOffset', 'offset': offset});
  }

  void beginSelection(TerminalCellPoint screenPoint) {
    _send({
      'type': 'selectionBegin',
      'row': screenPoint.row,
      'col': screenPoint.col,
    });
  }

  void updateSelectionEnd(TerminalCellPoint screenPoint) {
    _send({
      'type': 'selectionUpdateEnd',
      'row': screenPoint.row,
      'col': screenPoint.col,
    });
  }

  void setSelection({
    required TerminalCellPoint baseScreenPoint,
    required TerminalCellPoint extentScreenPoint,
  }) {
    _send({
      'type': 'selectionSet',
      'baseRow': baseScreenPoint.row,
      'baseCol': baseScreenPoint.col,
      'extentRow': extentScreenPoint.row,
      'extentCol': extentScreenPoint.col,
    });
  }

  void selectWord(TerminalCellPoint screenPoint) {
    _send({
      'type': 'selectionWord',
      'row': screenPoint.row,
      'col': screenPoint.col,
    });
  }

  void clearSelection() {
    _send({'type': 'selectionClear'});
  }

  Future<String?> copySelection() {
    if (_disposed) return Future<String?>.value(null);
    final id = _nextCopyRequestId++;
    final completer = Completer<String?>();
    _copySelectionRequests[id] = completer;
    _send({'type': 'selectionCopy', 'id': id});
    return completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _commandQueue.clear();
    _pendingFeedBytes = 0;
    for (final completer in _copySelectionRequests.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _copySelectionRequests.clear();
    await _eventsSub.cancel();
    _events.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  void _send(Map<String, Object?> message) {
    if (_disposed) return;
    _enqueue(_QueuedWorkerCommand.message(message));
  }

  void _enqueue(_QueuedWorkerCommand command) {
    if (_disposed || _backlogFailed) return;
    if (_commandQueue.length >= _maxPendingCommandCount) {
      _failBacklog(
        TerminalWorkerBacklogOverflow(
          pendingBytes: _pendingFeedBytes,
          limitBytes: _maxPendingFeedBytes,
        ),
      );
      return;
    }
    _commandQueue.addLast(command);
    _drainCommands();
  }

  void _drainCommands() {
    if (_disposed ||
        _backlogFailed ||
        _commandInFlight ||
        _commandQueue.isEmpty) {
      return;
    }
    final command = _commandQueue.removeFirst();
    final feedBytes = command.feedBytes;
    _commandInFlight = true;
    _commands.send({
      ...command.message,
      if (feedBytes != null)
        'bytes': TransferableTypedData.fromList([feedBytes]),
    });
  }

  void _failBacklog(TerminalWorkerBacklogOverflow error) {
    if (_disposed || _backlogFailed) return;
    _backlogFailed = true;
    _commandQueue.clear();
    _pendingFeedBytes = 0;
    _onError(error);
  }

  void _handleEvent(Object? message) {
    if (_disposed || message is! Map) return;
    switch (message['type']) {
      case 'initialized':
        _onInitialized();
      case 'hostWrite':
        final data = message['bytes'];
        if (data is TransferableTypedData) {
          _onHostWrite(data.materialize().asUint8List());
        }
      case 'frame':
        final frameId = message['frameId'];
        final data = message['bytes'];
        if (frameId is! int) return;
        var acknowledged = false;
        void acknowledge() {
          if (_disposed || acknowledged) return;
          acknowledged = true;
          _commands.send({'type': 'frameAck', 'frameId': frameId});
        }

        try {
          if (data is! TransferableTypedData) {
            throw const FormatException('terminal frame payload is missing');
          }
          final update = TerminalFrameUpdate.decode(
            data.materialize().asUint8List(),
          );
          if (update.frameId != frameId) {
            throw const FormatException('terminal frame id mismatch');
          }
          final snapshot = update.applyTo(_lastSnapshot);
          _lastSnapshot = snapshot;
          _onSnapshot(snapshot, acknowledge);
        } catch (error) {
          acknowledge();
          _commands.send({'type': 'frameResync'});
          Log.d(
            'discarding terminal frame $frameId: $error',
            name: 'motif.terminal.worker',
          );
        }
      case 'commandProcessed':
        final byteCount = message['feedBytes'];
        if (byteCount is int) {
          final remaining = _pendingFeedBytes - byteCount;
          _pendingFeedBytes = remaining > 0 ? remaining : 0;
        }
        _commandInFlight = false;
        _drainCommands();
      case 'selectionText':
        final id = message['id'];
        final completer = id is int ? _copySelectionRequests.remove(id) : null;
        if (completer != null && !completer.isCompleted) {
          final text = message['text'];
          completer.complete(text is String ? text : null);
        }
      case 'error':
        _onError(message['error'] ?? 'terminal worker error');
      case 'diagnostic':
        final text = '${message['message']}';
        if (message['info'] == true) {
          Log.i(text, name: 'motif.terminal.worker');
        } else {
          Log.d(text, name: 'motif.terminal.worker');
        }
    }
  }
}

void _terminalWorkerMain(SendPort events) {
  final commands = ReceivePort();
  final worker = _TerminalWorker(events, commands);
  events.send({'type': 'ready', 'port': commands.sendPort});
  worker.run();
}

class _TerminalWorker {
  _TerminalWorker(this.events, this.commands);

  static const Duration _interactiveFrameInterval = Duration(milliseconds: 16);
  static const Duration _cursorPollInterval = Duration(milliseconds: 500);

  final SendPort events;
  final ReceivePort commands;
  TerminalState? state;
  Timer? frameTimer;
  DateTime? frameDueAt;
  Timer? cursorTimer;
  bool forceSnapshot = false;
  bool forceFullFrame = true;
  bool framePendingWhileInFlight = false;
  int nextFrameId = 1;
  int lastSentFrameId = 0;
  int? inFlightFrameId;
  int foregroundArgb = 0xffffffff;
  int backgroundArgb = 0xff000000;
  _WorkerCursorSnapshot? lastCursor;
  final TerminalFramePacing framePacing = TerminalFramePacing();
  int diagnosticFeedChunks = 0;
  int diagnosticFeedBytes = 0;
  int diagnosticSnapshots = 0;
  Timer? initialSnapshotTimer;
  bool waitingForFirstFeed = false;

  void run() {
    commands.listen(_handleCommand);
  }

  void _handleCommand(Object? command) {
    if (command is! Map) return;
    switch (command['type']) {
      case 'frameAck':
        _ackFrame(command['frameId']);
        return;
      case 'frameResync':
        forceFullFrame = true;
        _scheduleSnapshot(force: true, delay: Duration.zero);
        return;
    }
    var processedFeedBytes = 0;
    try {
      switch (command['type']) {
        case 'init':
          _init(command);
        case 'theme':
          foregroundArgb = command['foregroundArgb'] as int;
          backgroundArgb = command['backgroundArgb'] as int;
          forceFullFrame = true;
          if (!waitingForFirstFeed) {
            _scheduleSnapshot(force: true, delay: Duration.zero);
          }
        case 'feed':
          final bytes = _materializeBytes(command['bytes']);
          if (bytes != null && bytes.isNotEmpty) {
            processedFeedBytes = bytes.length;
            final firstFeed = waitingForFirstFeed;
            if (firstFeed) {
              waitingForFirstFeed = false;
              initialSnapshotTimer?.cancel();
              initialSnapshotTimer = null;
            }
            final startedAtUs = DateTime.now().microsecondsSinceEpoch;
            final enqueuedAtUs = command['enqueuedAtUs'] as int?;
            final sw = Stopwatch()..start();
            state?.feedBytes(bytes);
            diagnosticFeedChunks++;
            diagnosticFeedBytes += bytes.length;
            if (diagnosticFeedChunks <= 3 ||
                diagnosticFeedChunks == 10 ||
                diagnosticFeedChunks % 1000 == 0) {
              events.send({
                'type': 'diagnostic',
                'info': diagnosticFeedChunks <= 10,
                'message':
                    'feed chunk=$diagnosticFeedChunks bytes=${bytes.length} '
                    'totalBytes=$diagnosticFeedBytes '
                    'queueLagUs=${enqueuedAtUs == null ? -1 : startedAtUs - enqueuedAtUs} '
                    'processUs=${sw.elapsedMicroseconds}',
              });
            }
            _scheduleSnapshot(
              force: true,
              delay: firstFeed ? Duration.zero : _feedFrameInterval,
            );
          }
        case 'resize':
          _resize(command);
        case 'writeBytes':
          final bytes = _materializeBytes(command['bytes']);
          if (bytes != null) {
            _markLocalInput();
            state?.writeToPty(bytes);
          }
        case 'paste':
          final bytes = _materializeBytes(command['bytes']);
          if (bytes != null) {
            _markLocalInput();
            state?.encodePasteAndWrite(bytes);
          }
        case 'key':
          _key(command);
        case 'mouse':
          _mouse(command);
        case 'focus':
          state?.encodeFocusAndWrite(command['gained'] == true);
        case 'scroll':
          framePacing.noteInteraction();
          state?.scroll(command['rows'] as int);
          // Frame acknowledgement already provides backpressure. Queue scroll
          // snapshots immediately so ProMotion displays are not capped by the
          // ordinary 16 ms interaction delay while chasing a fast flick.
          _scheduleSnapshot(force: true, delay: Duration.zero);
        case 'scrollToBottom':
          framePacing.noteInteraction();
          state?.scrollToBottom();
          _scheduleSnapshot(force: true);
        case 'scrollToOffset':
          framePacing.noteInteraction();
          state?.scrollToOffset(command['offset'] as int);
          _scheduleSnapshot(force: true, delay: Duration.zero);
        case 'selectionBegin':
          if (state?.beginTrackedSelection(_pointFromCommand(command)) ==
              true) {
            _scheduleSnapshot(force: true, delay: Duration.zero);
          }
        case 'selectionUpdateEnd':
          if (state?.updateTrackedSelectionEnd(_pointFromCommand(command)) ==
              true) {
            _scheduleSnapshot(force: true, delay: Duration.zero);
          }
        case 'selectionSet':
          if (state?.setTrackedSelection(
                TerminalCellPoint(
                  row: command['baseRow'] as int,
                  col: command['baseCol'] as int,
                ),
                TerminalCellPoint(
                  row: command['extentRow'] as int,
                  col: command['extentCol'] as int,
                ),
              ) ==
              true) {
            _scheduleSnapshot(force: true, delay: Duration.zero);
          }
        case 'selectionWord':
          if (state?.selectTrackedWordAtScreenPoint(
                _pointFromCommand(command),
              ) ==
              true) {
            _scheduleSnapshot(force: true, delay: Duration.zero);
          } else {
            _scheduleSnapshot(force: true, delay: Duration.zero);
          }
        case 'selectionClear':
          state?.clearTrackedSelection();
          _scheduleSnapshot(force: true, delay: Duration.zero);
        case 'selectionCopy':
          events.send({
            'type': 'selectionText',
            'id': command['id'],
            'text': state?.formatTrackedSelection(),
          });
        case 'dispose':
          _dispose();
      }
      events.send({
        'type': 'commandProcessed',
        'feedBytes': processedFeedBytes,
      });
    } catch (error) {
      events.send({'type': 'error', 'error': error.toString()});
    }
  }

  void _init(Map command) {
    _disposeState();
    foregroundArgb = command['foregroundArgb'] as int;
    backgroundArgb = command['backgroundArgb'] as int;
    final terminal = TerminalState(
      onHostWrite: (bytes) => events.send({
        'type': 'hostWrite',
        'bytes': TransferableTypedData.fromList([bytes]),
      }),
    );
    terminal.init(command['cols'] as int, command['rows'] as int);
    state = terminal;
    waitingForFirstFeed = command['waitForFirstFeed'] == true;
    _setMouseEncoderSize(command);
    events.send({'type': 'initialized'});
    if (waitingForFirstFeed) {
      final fallbackMs = command['initialSnapshotFallbackMs'] as int?;
      if (fallbackMs != null) {
        initialSnapshotTimer = Timer(Duration(milliseconds: fallbackMs), () {
          initialSnapshotTimer = null;
          waitingForFirstFeed = false;
          _scheduleSnapshot(force: true, delay: Duration.zero);
        });
      }
    } else {
      _scheduleSnapshot(force: true, delay: Duration.zero);
    }
  }

  void _resize(Map command) {
    final terminal = state;
    if (terminal == null) return;
    terminal.resize(
      command['cols'] as int,
      command['rows'] as int,
      command['cellWidth'] as int,
      command['cellHeight'] as int,
    );
    _setMouseEncoderSize(command);
    if (!waitingForFirstFeed) {
      _scheduleSnapshot(force: true, delay: Duration.zero);
    }
  }

  void _setMouseEncoderSize(Map command) {
    state?.setMouseEncoderSize(
      command['screenWidth'] as int,
      command['screenHeight'] as int,
      command['cellWidth'] as int,
      command['cellHeight'] as int,
      command['paddingLeft'] as int,
      command['paddingTop'] as int,
    );
  }

  void _key(Map command) {
    _markLocalInput();
    state?.encodeKeyAndWrite(
      GhosttyKey.fromValue(command['key'] as int),
      GhosttyKeyAction.fromValue(command['action'] as int),
      command['mods'] as int,
      command['text'] as String?,
      unshiftedCodepoint: command['unshiftedCodepoint'] as int,
    );
  }

  void _mouse(Map command) {
    _markLocalInput();
    state?.encodeMouseAndWrite(
      GhosttyMouseAction.fromValue(command['action'] as int),
      GhosttyMouseButton.fromValue(command['button'] as int),
      command['mods'] as int,
      command['x'] as double,
      command['y'] as double,
    );
  }

  Uint8List? _materializeBytes(Object? bytes) {
    if (bytes is TransferableTypedData) {
      return bytes.materialize().asUint8List();
    }
    if (bytes is Uint8List) return bytes;
    return null;
  }

  TerminalCellPoint _pointFromCommand(Map command) {
    return TerminalCellPoint(
      row: command['row'] as int,
      col: command['col'] as int,
    );
  }

  Duration get _feedFrameInterval {
    return framePacing.intervalForOutput();
  }

  void _markLocalInput() {
    framePacing.noteInteraction();
  }

  void _scheduleSnapshot({
    required bool force,
    Duration delay = _interactiveFrameInterval,
  }) {
    forceSnapshot = forceSnapshot || force;
    if (state == null) return;
    if (inFlightFrameId != null) {
      framePendingWhileInFlight = true;
      return;
    }
    final dueAt = DateTime.now().add(delay);
    final existingDueAt = frameDueAt;
    if (frameTimer != null &&
        existingDueAt != null &&
        !dueAt.isBefore(existingDueAt)) {
      return;
    }
    // Interaction (scrolling, selection, resize) must be able to bring an
    // already scheduled output frame forward instead of waiting behind it.
    frameTimer?.cancel();
    cursorTimer?.cancel();
    cursorTimer = null;
    frameDueAt = dueAt;
    frameTimer = Timer(delay, _pumpFrame);
  }

  void _scheduleCursorPoll() {
    if (state == null ||
        inFlightFrameId != null ||
        frameTimer != null ||
        cursorTimer != null) {
      return;
    }
    cursorTimer = Timer(_cursorPollInterval, _pumpFrame);
  }

  void _pumpFrame() {
    frameTimer = null;
    frameDueAt = null;
    cursorTimer = null;
    final terminal = state;
    if (terminal == null) return;
    if (inFlightFrameId != null) {
      framePendingWhileInFlight = true;
      return;
    }
    final sw = Stopwatch()..start();
    terminal.updateRenderState();
    final dirty = terminal.getDirty();
    final cursorState = terminal.readCursorState();
    final cursor = _WorkerCursorSnapshot.fromRecord(cursorState);
    final cursorChanged = cursor != lastCursor;
    lastCursor = cursor;
    if (dirty == GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE &&
        !cursorChanged &&
        !forceSnapshot &&
        !forceFullFrame) {
      _scheduleCursorPoll();
      return;
    }
    final full =
        forceFullFrame ||
        dirty == GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FULL;
    forceSnapshot = false;
    forceFullFrame = false;
    final metadata = terminal.captureFrameMetadata(
      defaultForegroundArgb: foregroundArgb,
      defaultBackgroundArgb: backgroundArgb,
      cursor: cursorState,
      selection: terminal.trackedSelection(),
    );
    final frameId = nextFrameId++;
    final encoded = terminal.encodeFrame(
      frameId: frameId,
      baseFrameId: full ? 0 : lastSentFrameId,
      full: full,
      metadata: metadata,
    );
    framePacing.observeViewportOffset(metadata.viewportOffset);
    diagnosticSnapshots++;
    inFlightFrameId = frameId;
    lastSentFrameId = frameId;
    events.send({
      'type': 'frame',
      'frameId': frameId,
      'bytes': TransferableTypedData.fromList([encoded.bytes]),
    });
    if (diagnosticSnapshots <= 3 || diagnosticSnapshots % 100 == 0) {
      events.send({
        'type': 'diagnostic',
        'info': diagnosticSnapshots <= 3,
        'message':
            'frame count=$diagnosticSnapshots full=$full '
            'rows=${encoded.encodedRows} cells=${encoded.encodedCells} '
            'bytes=${encoded.bytes.length} '
            'feedChunks=$diagnosticFeedChunks feedBytes=$diagnosticFeedBytes '
            'buildUs=${sw.elapsedMicroseconds}',
      });
    }
  }

  void _ackFrame(Object? value) {
    if (value is! int || value != inFlightFrameId) return;
    inFlightFrameId = null;
    if (framePendingWhileInFlight || forceSnapshot || forceFullFrame) {
      framePendingWhileInFlight = false;
      _scheduleSnapshot(force: false, delay: Duration.zero);
    } else {
      _scheduleCursorPoll();
    }
  }

  void _dispose() {
    _disposeState();
    commands.close();
  }

  void _disposeState() {
    initialSnapshotTimer?.cancel();
    initialSnapshotTimer = null;
    frameTimer?.cancel();
    frameTimer = null;
    frameDueAt = null;
    cursorTimer?.cancel();
    cursorTimer = null;
    state?.dispose();
    state = null;
    lastCursor = null;
    framePacing.reset();
    forceSnapshot = false;
    forceFullFrame = true;
    framePendingWhileInFlight = false;
    nextFrameId = 1;
    lastSentFrameId = 0;
    inFlightFrameId = null;
    waitingForFirstFeed = false;
    diagnosticFeedChunks = 0;
    diagnosticFeedBytes = 0;
    diagnosticSnapshots = 0;
  }
}

class _WorkerCursorSnapshot {
  final bool visible;
  final bool inViewport;
  final int x;
  final int y;
  final int style;
  final int? colorArgb;

  const _WorkerCursorSnapshot({
    required this.visible,
    required this.inViewport,
    required this.x,
    required this.y,
    required this.style,
    required this.colorArgb,
  });

  factory _WorkerCursorSnapshot.fromRecord(
    ({bool visible, bool inViewport, int x, int y, int style, int? colorArgb})
    cursor,
  ) {
    return _WorkerCursorSnapshot(
      visible: cursor.visible,
      inViewport: cursor.inViewport,
      x: cursor.x,
      y: cursor.y,
      style: cursor.style,
      colorArgb: cursor.colorArgb,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _WorkerCursorSnapshot &&
          other.visible == visible &&
          other.inViewport == inViewport &&
          other.x == x &&
          other.y == y &&
          other.style == style &&
          other.colorArgb == colorArgb;

  @override
  int get hashCode => Object.hash(visible, inViewport, x, y, style, colorArgb);
}
