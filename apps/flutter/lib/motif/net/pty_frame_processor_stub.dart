import 'dart:typed_data';

import 'pty_frame_codec.dart';
import 'pty_frame_processor_types.dart';
import 'shell_integration.dart';

/// Browser fallback. Native platforms use the isolate-backed implementation.
class PtyFrameProcessor {
  final Map<String, ShellState> _shells = {};

  static Future<PtyFrameProcessor> spawn() async => PtyFrameProcessor();

  Future<ProcessedPtyFrame> process(
    String ptyId,
    Uint8List payload, {
    required bool framedZlib,
  }) async {
    final decoded = decodePtyPayload(payload, framedZlib: framedZlib);
    final shell = _shells.putIfAbsent(ptyId, ShellState.new);
    final result = shell.feed(decoded);
    return ProcessedPtyFrame(
      passthrough: result.passthrough,
      events: result.events,
      blockId: shell.activeBlockId,
      scope: shell.activeScope,
      decodedLength: decoded.length,
    );
  }

  Future<void> primeRunning(String ptyId, String command) async {
    _shells.putIfAbsent(ptyId, ShellState.new).primeRunning(command);
  }

  Future<void> removePty(String ptyId) async {
    _shells.remove(ptyId);
  }

  Future<void> dispose() async {
    _shells.clear();
  }
}
