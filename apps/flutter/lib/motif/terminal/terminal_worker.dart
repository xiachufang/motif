import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../log/log.dart';
import 'ghostty_bindings.g.dart';
import 'terminal_snapshot.dart';
import 'terminal_state.dart';

typedef TerminalWorkerBytesCallback = void Function(Uint8List bytes);
typedef TerminalWorkerSnapshotCallback =
    void Function(TerminalSnapshot snapshot);
typedef TerminalWorkerErrorCallback = void Function(Object error);

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
  late final StreamSubscription<Object?> _eventsSub;
  bool _disposed = false;
  int _nextCopyRequestId = 1;
  final Map<int, Completer<String?>> _copySelectionRequests =
      <int, Completer<String?>>{};

  static Future<TerminalWorkerClient> spawn({
    required TerminalWorkerBytesCallback onHostWrite,
    required TerminalWorkerSnapshotCallback onSnapshot,
    required void Function() onInitialized,
    required TerminalWorkerErrorCallback onError,
  }) async {
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
    if (bytes.isEmpty) return;
    _send({
      'type': 'feed',
      'bytes': TransferableTypedData.fromList([bytes]),
      'enqueuedAtUs': DateTime.now().microsecondsSinceEpoch,
    });
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

  void beginSelection(TerminalCellPoint viewportPoint) {
    _send({
      'type': 'selectionBegin',
      'row': viewportPoint.row,
      'col': viewportPoint.col,
    });
  }

  void updateSelectionEnd(TerminalCellPoint viewportPoint) {
    _send({
      'type': 'selectionUpdateEnd',
      'row': viewportPoint.row,
      'col': viewportPoint.col,
    });
  }

  void setSelection({
    required TerminalCellPoint baseViewportPoint,
    required TerminalCellPoint extentViewportPoint,
  }) {
    _send({
      'type': 'selectionSet',
      'baseRow': baseViewportPoint.row,
      'baseCol': baseViewportPoint.col,
      'extentRow': extentViewportPoint.row,
      'extentCol': extentViewportPoint.col,
    });
  }

  void selectWord(TerminalCellPoint viewportPoint) {
    _send({
      'type': 'selectionWord',
      'row': viewportPoint.row,
      'col': viewportPoint.col,
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
    for (final completer in _copySelectionRequests.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _copySelectionRequests.clear();
    _send({'type': 'dispose'});
    await _eventsSub.cancel();
    _events.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  void _send(Map<String, Object?> message) {
    if (_disposed) return;
    _commands.send(message);
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
      case 'snapshot':
        final snapshot = message['snapshot'];
        if (snapshot is TerminalSnapshot) _onSnapshot(snapshot);
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

  static const Duration _remoteOutputFrameInterval = Duration(milliseconds: 50);
  static const Duration _busyRemoteOutputFrameInterval = Duration(
    milliseconds: 66,
  );
  static const Duration _sustainedRemoteOutputFrameInterval = Duration(
    milliseconds: 80,
  );
  static const Duration _interactiveFrameInterval = Duration(milliseconds: 16);
  static const Duration _localEchoWindow = Duration(milliseconds: 150);
  static const Duration _remoteBurstResetGap = Duration(milliseconds: 250);
  static const Duration _busyOutputWindow = Duration(milliseconds: 500);
  static const Duration _sustainedOutputWindow = Duration(milliseconds: 1200);
  static const int _busyOutputMinBytes = 4 * 1024;
  static const int _busyOutputMinChunks = 12;
  static const int _sustainedOutputMinBytes = 16 * 1024;
  static const int _sustainedOutputMinChunks = 30;
  static const Duration _cursorPollInterval = Duration(milliseconds: 500);

  final SendPort events;
  final ReceivePort commands;
  TerminalState? state;
  Timer? frameTimer;
  Timer? cursorTimer;
  bool forceSnapshot = false;
  int foregroundArgb = 0xffffffff;
  int backgroundArgb = 0xff000000;
  _WorkerCursorSnapshot? lastCursor;
  DateTime? lastLocalInputAt;
  DateTime? lastRemoteFeedAt;
  DateTime? remoteBurstStartedAt;
  int remoteBurstBytes = 0;
  int remoteBurstChunks = 0;
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
    try {
      switch (command['type']) {
        case 'init':
          _init(command);
        case 'theme':
          foregroundArgb = command['foregroundArgb'] as int;
          backgroundArgb = command['backgroundArgb'] as int;
          if (!waitingForFirstFeed) {
            _scheduleSnapshot(force: true, delay: Duration.zero);
          }
        case 'feed':
          final bytes = _materializeBytes(command['bytes']);
          if (bytes != null && bytes.isNotEmpty) {
            final firstFeed = waitingForFirstFeed;
            if (firstFeed) {
              waitingForFirstFeed = false;
              initialSnapshotTimer?.cancel();
              initialSnapshotTimer = null;
            }
            final startedAtUs = DateTime.now().microsecondsSinceEpoch;
            final enqueuedAtUs = command['enqueuedAtUs'] as int?;
            final sw = Stopwatch()..start();
            _noteRemoteFeed(bytes.length);
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
        case 'key':
          _key(command);
        case 'mouse':
          _mouse(command);
        case 'focus':
          state?.encodeFocusAndWrite(command['gained'] == true);
        case 'scroll':
          state?.scroll(command['rows'] as int);
          _scheduleSnapshot(force: true);
        case 'scrollToBottom':
          state?.scrollToBottom();
          _scheduleSnapshot(force: true);
        case 'scrollToOffset':
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
          if (state?.selectTrackedWordAtViewportPoint(
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
    final now = DateTime.now();
    final inputAt = lastLocalInputAt;
    if (inputAt != null && now.difference(inputAt) <= _localEchoWindow) {
      return _interactiveFrameInterval;
    }

    final burstStarted = remoteBurstStartedAt;
    if (burstStarted == null) return _remoteOutputFrameInterval;
    final burstElapsed = now.difference(burstStarted);
    if (burstElapsed >= _sustainedOutputWindow &&
        (remoteBurstChunks >= _sustainedOutputMinChunks ||
            remoteBurstBytes >= _sustainedOutputMinBytes)) {
      return _sustainedRemoteOutputFrameInterval;
    }
    if (burstElapsed >= _busyOutputWindow &&
        (remoteBurstChunks >= _busyOutputMinChunks ||
            remoteBurstBytes >= _busyOutputMinBytes)) {
      return _busyRemoteOutputFrameInterval;
    }
    return _remoteOutputFrameInterval;
  }

  void _noteRemoteFeed(int byteCount) {
    final now = DateTime.now();
    final previousFeed = lastRemoteFeedAt;
    if (previousFeed == null ||
        now.difference(previousFeed) > _remoteBurstResetGap) {
      remoteBurstStartedAt = now;
      remoteBurstBytes = 0;
      remoteBurstChunks = 0;
    }
    lastRemoteFeedAt = now;
    remoteBurstBytes += byteCount;
    remoteBurstChunks++;
  }

  void _markLocalInput() {
    lastLocalInputAt = DateTime.now();
  }

  void _resetRemoteBurst() {
    lastRemoteFeedAt = null;
    remoteBurstStartedAt = null;
    remoteBurstBytes = 0;
    remoteBurstChunks = 0;
  }

  void _scheduleSnapshot({
    required bool force,
    Duration delay = _interactiveFrameInterval,
  }) {
    forceSnapshot = forceSnapshot || force;
    if (state == null || frameTimer != null) return;
    cursorTimer?.cancel();
    cursorTimer = null;
    frameTimer = Timer(delay, _pumpFrame);
  }

  void _scheduleCursorPoll() {
    if (state == null || frameTimer != null || cursorTimer != null) return;
    cursorTimer = Timer(_cursorPollInterval, _pumpFrame);
  }

  void _pumpFrame() {
    frameTimer = null;
    cursorTimer = null;
    final terminal = state;
    if (terminal == null) return;
    final sw = Stopwatch()..start();
    terminal.updateRenderState();
    final dirty =
        terminal.getDirty() !=
        GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    final cursor = _WorkerCursorSnapshot.fromState(terminal);
    final cursorChanged = cursor != lastCursor;
    lastCursor = cursor;
    if (!dirty && !cursorChanged && !forceSnapshot) {
      _scheduleCursorPoll();
      return;
    }
    forceSnapshot = false;
    final snapshot = terminal.snapshot(
      defaultForegroundArgb: foregroundArgb,
      defaultBackgroundArgb: backgroundArgb,
      selection: terminal.trackedSelection(),
    );
    diagnosticSnapshots++;
    events.send({'type': 'snapshot', 'snapshot': snapshot});
    if (diagnosticSnapshots <= 3 || diagnosticSnapshots % 100 == 0) {
      events.send({
        'type': 'diagnostic',
        'info': diagnosticSnapshots <= 3,
        'message':
            'snapshot count=$diagnosticSnapshots rows=${snapshot.lines.length} '
            'feedChunks=$diagnosticFeedChunks feedBytes=$diagnosticFeedBytes '
            'buildUs=${sw.elapsedMicroseconds}',
      });
    }
    _scheduleCursorPoll();
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
    cursorTimer?.cancel();
    cursorTimer = null;
    state?.dispose();
    state = null;
    lastCursor = null;
    forceSnapshot = false;
    waitingForFirstFeed = false;
    _resetRemoteBurst();
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

  const _WorkerCursorSnapshot({
    required this.visible,
    required this.inViewport,
    required this.x,
    required this.y,
    required this.style,
  });

  factory _WorkerCursorSnapshot.fromState(TerminalState state) {
    final inViewport = state.cursorInViewport;
    return _WorkerCursorSnapshot(
      visible: state.cursorVisible,
      inViewport: inViewport,
      x: inViewport ? state.cursorX : -1,
      y: inViewport ? state.cursorY : -1,
      style: state.cursorStyle.value,
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
          other.style == style;

  @override
  int get hashCode => Object.hash(visible, inViewport, x, y, style);
}
