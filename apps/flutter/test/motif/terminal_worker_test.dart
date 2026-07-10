import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/terminal_snapshot.dart';
import 'package:motif/motif/terminal/terminal_worker.dart';

void main() {
  test('worker owns Ghostty state and emits snapshots', () async {
    final initialized = Completer<void>();
    final snapshots = StreamController<TerminalSnapshot>.broadcast();
    final hostWrites = <int>[];

    final worker = await TerminalWorkerClient.spawn(
      onHostWrite: (bytes) => hostWrites.addAll(bytes),
      onSnapshot: snapshots.add,
      onInitialized: initialized.complete,
      onError: (error) => fail('worker error: $error'),
    );
    addTearDown(() async {
      await snapshots.close();
      await worker.dispose();
    });

    worker.init(
      cols: 20,
      rows: 4,
      screenWidth: 200,
      screenHeight: 80,
      cellWidth: 10,
      cellHeight: 20,
      paddingLeft: 0,
      paddingTop: 0,
      foregroundArgb: 0xffffffff,
      backgroundArgb: 0xff000000,
    );
    await initialized.future.timeout(const Duration(seconds: 2));

    worker.feedBytes(Uint8List.fromList(utf8.encode('hello')));
    final snapshot = await snapshots.stream
        .firstWhere((s) => s.visibleText.contains('hello'))
        .timeout(const Duration(seconds: 2));
    expect(snapshot.visibleText, contains('hello'));

    worker.feedBytes(
      Uint8List.fromList(
        utf8.encode(List.generate(12, (i) => 'line$i').join('\r\n')),
      ),
    );
    final scrollback = await snapshots.stream
        .firstWhere((s) => s.hasScrollback && s.viewportOffset > 0)
        .timeout(const Duration(seconds: 2));
    expect(scrollback.viewportOffset, scrollback.maxViewportOffset);

    worker.scrollToOffset(0);
    final top = await snapshots.stream
        .firstWhere((s) => s.hasScrollback && s.viewportOffset == 0)
        .timeout(const Duration(seconds: 2));
    expect(top.viewportOffset, 0);

    worker.writeBytes(Uint8List.fromList([0x61]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(hostWrites, contains(0x61));
  });
}
