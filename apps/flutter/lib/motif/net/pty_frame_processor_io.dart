import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'pty_frame_codec.dart';
import 'pty_frame_processor_types.dart';
import 'shell_integration.dart';

class PtyFrameProcessor {
  PtyFrameProcessor._(
    this._isolate,
    this._receive,
    this._subscription,
    this._commands,
  );

  final Isolate _isolate;
  final ReceivePort _receive;
  late final StreamSubscription<Object?> _subscription;
  final SendPort _commands;
  final Map<int, Completer<Map<Object?, Object?>>> _pending = {};
  int _nextRequestId = 1;
  bool _disposed = false;

  static Future<PtyFrameProcessor> spawn() async {
    final receive = ReceivePort();
    final ready = Completer<SendPort>();
    PtyFrameProcessor? processor;
    late final StreamSubscription<Object?> subscription;
    final isolate = await Isolate.spawn(
      _ptyFrameProcessorMain,
      receive.sendPort,
      debugName: 'MotifPtyFrameProcessor',
      onError: receive.sendPort,
      onExit: receive.sendPort,
    );
    subscription = receive.listen((message) {
      if (message is SendPort && !ready.isCompleted) {
        ready.complete(message);
        return;
      }
      if (message is Map) {
        final response = message.cast<Object?, Object?>();
        final id = response['id'];
        if (id is int) {
          final completer = processor?._pending.remove(id);
          if (completer != null && !completer.isCompleted) {
            if (response['error'] case final String error) {
              completer.completeError(StateError(error));
            } else {
              completer.complete(response);
            }
          }
        }
        return;
      }
      final error = message is List && message.isNotEmpty
          ? '${message.first}'
          : 'PTY frame processor exited unexpectedly';
      if (!ready.isCompleted) {
        ready.completeError(StateError(error));
      } else {
        processor?._failPending(StateError(error));
      }
    });
    final commands = await ready.future;
    final result = PtyFrameProcessor._(
      isolate,
      receive,
      subscription,
      commands,
    );
    processor = result;
    return result;
  }

  Future<ProcessedPtyFrame> process(
    String ptyId,
    Uint8List payload, {
    required bool framedZlib,
  }) async {
    final response = await _request({
      'type': 'process',
      'ptyId': ptyId,
      'payload': TransferableTypedData.fromList([payload]),
      'framedZlib': framedZlib,
    });
    final transferred = response['passthrough'];
    if (transferred is! TransferableTypedData) {
      throw StateError('PTY processor returned no passthrough data');
    }
    return ProcessedPtyFrame(
      passthrough: transferred.materialize().asUint8List(),
      events: List<ShellEvent>.from((response['events'] as List?) ?? const []),
      blockId: response['blockId'] as String?,
      scope: ShellOutputScope.values[response['scope'] as int],
      decodedLength: response['decodedLength'] as int,
    );
  }

  Future<void> primeRunning(String ptyId, String command) async {
    await _request({'type': 'prime', 'ptyId': ptyId, 'command': command});
  }

  Future<void> removePty(String ptyId) async {
    await _request({'type': 'remove', 'ptyId': ptyId});
  }

  Future<Map<Object?, Object?>> _request(Map<Object?, Object?> command) {
    if (_disposed) {
      return Future.error(StateError('PTY frame processor is disposed'));
    }
    final id = _nextRequestId++;
    final completer = Completer<Map<Object?, Object?>>();
    _pending[id] = completer;
    _commands.send({...command, 'id': id});
    return completer.future;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _isolate.kill(priority: Isolate.immediate);
    _failPending(StateError('PTY frame processor disposed'));
    await _subscription.cancel();
    _receive.close();
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }
}

@pragma('vm:entry-point')
void _ptyFrameProcessorMain(SendPort events) {
  final commands = ReceivePort();
  final shells = <String, ShellState>{};
  events.send(commands.sendPort);
  commands.listen((message) {
    if (message is! Map) return;
    final command = message.cast<Object?, Object?>();
    final id = command['id'];
    if (id is! int) return;
    try {
      final type = command['type'];
      final ptyId = command['ptyId'] as String?;
      switch (type) {
        case 'process':
          final transferred = command['payload'];
          if (ptyId == null || transferred is! TransferableTypedData) {
            throw StateError('invalid process command');
          }
          final payload = transferred.materialize().asUint8List();
          final decoded = decodePtyPayload(
            payload,
            framedZlib: command['framedZlib'] == true,
          );
          final shell = shells.putIfAbsent(ptyId, ShellState.new);
          final result = shell.feed(decoded);
          events.send({
            'id': id,
            'passthrough': TransferableTypedData.fromList([result.passthrough]),
            'events': result.events,
            'blockId': shell.activeBlockId,
            'scope': shell.activeScope.index,
            'decodedLength': decoded.length,
          });
        case 'prime':
          if (ptyId == null) throw StateError('invalid prime command');
          shells
              .putIfAbsent(ptyId, ShellState.new)
              .primeRunning(command['command'] as String);
          events.send({'id': id});
        case 'remove':
          if (ptyId != null) shells.remove(ptyId);
          events.send({'id': id});
        default:
          throw StateError('unknown PTY processor command: $type');
      }
    } catch (error, stackTrace) {
      events.send({'id': id, 'error': '$error\n$stackTrace'});
    }
  });
}
