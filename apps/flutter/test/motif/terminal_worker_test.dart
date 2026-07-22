@Tags(['native'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/terminal/ghostty_bindings.g.dart';
import 'package:motif/motif/terminal/terminal_snapshot.dart';
import 'package:motif/motif/terminal/terminal_worker.dart';

void main() {
  test('worker client caps queued PTY bytes', () async {
    final overflow = Completer<Object>();
    final worker = await TerminalWorkerClient.spawn(
      onHostWrite: (_) {},
      onSnapshot: (_, acknowledge) => acknowledge(),
      onInitialized: () {},
      onError: overflow.complete,
      maxPendingFeedBytes: 4,
    );
    addTearDown(worker.dispose);

    worker.feedBytes(Uint8List.fromList([1, 2, 3, 4, 5]));

    final error = await overflow.future.timeout(const Duration(seconds: 2));
    expect(error, isA<TerminalWorkerBacklogOverflow>());
    expect('$error', contains('5 > 4 bytes'));
  });

  test('worker owns Ghostty state and emits snapshots', () async {
    final initialized = Completer<void>();
    final snapshots = StreamController<TerminalSnapshot>.broadcast();
    final emittedSnapshots = <TerminalSnapshot>[];
    final hostWrites = <int>[];

    final worker = await TerminalWorkerClient.spawn(
      onHostWrite: (bytes) => hostWrites.addAll(bytes),
      onSnapshot: (snapshot, acknowledge) {
        emittedSnapshots.add(snapshot);
        snapshots.add(snapshot);
        acknowledge();
      },
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
      waitForFirstFeed: true,
    );
    await initialized.future.timeout(const Duration(seconds: 2));

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(emittedSnapshots, isEmpty);
    final firstContent = snapshots.stream.firstWhere(
      (s) => s.visibleText.contains('hello'),
    );
    worker.feedBytes(Uint8List.fromList(utf8.encode('hello')));
    final snapshot = await firstContent.timeout(const Duration(seconds: 2));
    expect(snapshot.visibleText, contains('hello'));

    final orderedBurst = snapshots.stream.firstWhere(
      (s) => s.visibleText.contains('helloABC'),
    );
    worker.feedBytes(Uint8List.fromList(utf8.encode('A')));
    worker.feedBytes(Uint8List.fromList(utf8.encode('B')));
    worker.feedBytes(Uint8List.fromList(utf8.encode('C')));
    await orderedBurst.timeout(const Duration(seconds: 2));

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

  test('worker returns OSC 8 URI for a linked cell', () async {
    const uri = 'https://example.com/worker-link';
    final initialized = Completer<void>();
    final linkedFrame = Completer<TerminalSnapshot>();
    final worker = await TerminalWorkerClient.spawn(
      onHostWrite: (_) {},
      onSnapshot: (snapshot, acknowledge) {
        acknowledge();
        if (!linkedFrame.isCompleted &&
            snapshot.hasHyperlinkAt(const TerminalCellPoint(row: 0, col: 0))) {
          linkedFrame.complete(snapshot);
        }
      },
      onInitialized: initialized.complete,
      onError: (error) => fail('worker error: $error'),
    );
    addTearDown(worker.dispose);

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
      waitForFirstFeed: true,
    );
    await initialized.future.timeout(const Duration(seconds: 2));
    worker.feedBytes(
      Uint8List.fromList(utf8.encode('\x1b]8;;$uri\x07link\x1b]8;;\x07')),
    );
    await linkedFrame.future.timeout(const Duration(seconds: 2));

    expect(
      await worker
          .hyperlinkAt(const TerminalCellPoint(row: 0, col: 2))
          .timeout(const Duration(seconds: 2)),
      uri,
    );
    expect(
      await worker
          .hyperlinkAt(const TerminalCellPoint(row: 0, col: 4))
          .timeout(const Duration(seconds: 2)),
      isNull,
    );
  });

  test(
    'key encoding observes an immediately preceding terminal mode',
    () async {
      final initialized = Completer<void>();
      final hostWrite = Completer<Uint8List>();
      final worker = await TerminalWorkerClient.spawn(
        onHostWrite: (bytes) {
          if (!hostWrite.isCompleted) hostWrite.complete(bytes);
        },
        onSnapshot: (_, acknowledge) => acknowledge(),
        onInitialized: initialized.complete,
        onError: (error) => fail('worker error: $error'),
      );
      addTearDown(worker.dispose);

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

      // DECCKM is parsed before the following key command, even though both are
      // enqueued without yielding back to the event loop.
      worker.feedBytes(
        Uint8List.fromList(const [0x1b, 0x5b, 0x3f, 0x31, 0x68]),
      );
      worker.encodeKey(
        key: GhosttyKey.GHOSTTY_KEY_ARROW_UP,
        action: GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
        mods: 0,
        text: null,
        unshiftedCodepoint: 0,
      );

      expect(await hostWrite.future.timeout(const Duration(seconds: 2)), [
        0x1b,
        0x4f,
        0x41,
      ]);
    },
  );

  test(
    'worker waits for frame acknowledgement before emitting another',
    () async {
      final initialized = Completer<void>();
      final firstFrame = Completer<void>();
      final secondFrame = Completer<TerminalSnapshot>();
      late void Function() acknowledgeFirst;
      var deliveredFrames = 0;

      final worker = await TerminalWorkerClient.spawn(
        onHostWrite: (_) {},
        onSnapshot: (snapshot, acknowledge) {
          deliveredFrames++;
          if (!firstFrame.isCompleted) {
            acknowledgeFirst = acknowledge;
            firstFrame.complete();
            return;
          }
          acknowledge();
          if (!secondFrame.isCompleted) secondFrame.complete(snapshot);
        },
        onInitialized: initialized.complete,
        onError: (error) => fail('worker error: $error'),
      );
      addTearDown(worker.dispose);

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
        waitForFirstFeed: true,
      );
      await initialized.future.timeout(const Duration(seconds: 2));

      worker.feedBytes(Uint8List.fromList(utf8.encode('A')));
      await firstFrame.future.timeout(const Duration(seconds: 2));
      worker.feedBytes(Uint8List.fromList(utf8.encode('B')));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(deliveredFrames, 1);

      acknowledgeFirst();
      final snapshot = await secondFrame.future.timeout(
        const Duration(seconds: 2),
      );
      expect(snapshot.visibleText, contains('AB'));
    },
  );
}
