import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/net/pty_frame_processor.dart';
import 'package:motif/motif/net/shell_integration.dart';

void main() {
  test('inflates and parses PTY frames away from the caller', () async {
    final processor = await PtyFrameProcessor.spawn();
    addTearDown(processor.dispose);
    final decoded = utf8.encode('before\x1b]7777;A\x07after');
    final compressed = const ZLibEncoder().encode(decoded);
    final payload = Uint8List.fromList([0x01, ...compressed]);

    var callerYielded = false;
    scheduleMicrotask(() => callerYielded = true);
    final result = await processor.process('pty-1', payload, framedZlib: true);

    expect(callerYielded, isTrue);
    expect(utf8.decode(result.passthrough), 'beforeafter');
    expect(result.decodedLength, decoded.length);
    expect(result.events.whereType<ShellBootstrapped>(), hasLength(1));
    expect(result.events.whereType<ShellPromptStarted>(), hasLength(1));
    expect(result.scope, ShellOutputScope.prompt);
  });

  test('keeps shell state per PTY and supports cold-attach priming', () async {
    final processor = await PtyFrameProcessor.spawn();
    addTearDown(processor.dispose);
    await processor.primeRunning('pty-1', 'sleep 60');

    final result = await processor.process(
      'pty-1',
      Uint8List.fromList(utf8.encode('\x1b]133;D;0\x07')),
      framedZlib: false,
    );

    final finished = result.events.whereType<ShellCommandFinished>().single;
    expect(finished.exitCode, 0);
    expect(result.scope, ShellOutputScope.passthrough);
  });
}
