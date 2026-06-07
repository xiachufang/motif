import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
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
      case 'error':
        _onError(message['error'] ?? 'terminal worker error');
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

  final SendPort events;
  final ReceivePort commands;
  TerminalState? state;
  Timer? frameTimer;
  bool forceSnapshot = false;
  int foregroundArgb = 0xffffffff;
  int backgroundArgb = 0xff000000;
  _WorkerCursorSnapshot? lastCursor;

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
          _scheduleSnapshot(force: true);
        case 'feed':
          final bytes = _materializeBytes(command['bytes']);
          if (bytes != null && bytes.isNotEmpty) {
            state?.feedBytes(bytes);
            _scheduleSnapshot(force: true);
          }
        case 'resize':
          _resize(command);
        case 'writeBytes':
          final bytes = _materializeBytes(command['bytes']);
          if (bytes != null) state?.writeToPty(bytes);
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
    _setMouseEncoderSize(command);
    events.send({'type': 'initialized'});
    frameTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _pumpFrame(),
    );
    _scheduleSnapshot(force: true);
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
    _scheduleSnapshot(force: true);
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
    state?.encodeKeyAndWrite(
      GhosttyKey.fromValue(command['key'] as int),
      GhosttyKeyAction.fromValue(command['action'] as int),
      command['mods'] as int,
      command['text'] as String?,
      unshiftedCodepoint: command['unshiftedCodepoint'] as int,
    );
  }

  void _mouse(Map command) {
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

  void _scheduleSnapshot({required bool force}) {
    forceSnapshot = forceSnapshot || force;
  }

  void _pumpFrame() {
    final terminal = state;
    if (terminal == null) return;
    terminal.updateRenderState();
    final dirty =
        terminal.getDirty() !=
        GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    final cursor = _WorkerCursorSnapshot.fromState(terminal);
    final cursorChanged = cursor != lastCursor;
    lastCursor = cursor;
    if (!dirty && !cursorChanged && !forceSnapshot) return;
    forceSnapshot = false;
    events.send({
      'type': 'snapshot',
      'snapshot': terminal.snapshot(
        defaultForegroundArgb: foregroundArgb,
        defaultBackgroundArgb: backgroundArgb,
      ),
    });
  }

  void _dispose() {
    _disposeState();
    commands.close();
  }

  void _disposeState() {
    frameTimer?.cancel();
    frameTimer = null;
    state?.dispose();
    state = null;
    lastCursor = null;
    forceSnapshot = false;
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
