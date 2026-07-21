import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/workspace/terminal/terminal_runtime_policy.dart';
import 'package:motif/motif/state/workspace/terminal/terminal_stream_runtime.dart';

void main() {
  test('desktop restores active PTY before background streams', () async {
    final host = _StreamHost(activePtyId: 'p1', liveTabPtyIds: {'p1', 'p2'});
    final runtime = TerminalStreamRuntimeController(
      host: host,
      policy: TerminalStreamPlatformPolicy.desktop,
      backgroundRestoreDelay: Duration.zero,
      onStateChanged: (_) {},
    );
    addTearDown(runtime.dispose);

    runtime.sessionAttached();
    expect(host.synced, [
      {'p1'},
    ]);
    expect(runtime.state.status, isA<TerminalStreamsSynchronizing>());

    host.completeReplay('p1');
    await _flushEffects();

    expect(host.synced, [
      {'p1'},
      {'p1', 'p2'},
    ]);
    expect(runtime.state.status, isA<TerminalStreamsReady>());
  });

  test('new desktop target invalidates staged replay restore', () async {
    final host = _StreamHost(activePtyId: 'p1', liveTabPtyIds: {'p1', 'p2'});
    final runtime = TerminalStreamRuntimeController(
      host: host,
      policy: TerminalStreamPlatformPolicy.desktop,
      backgroundRestoreDelay: Duration.zero,
      onStateChanged: (_) {},
    );
    addTearDown(runtime.dispose);

    runtime.sessionAttached();
    host.liveTabPtyIds = {'p2'};
    runtime.subscriptionsChanged();
    await _flushEffects();

    expect(host.synced.last, {'p2'});
    expect(
      runtime.state.status,
      isA<TerminalStreamsReady>().having(
        (state) => state.subscribedPtyIds,
        'subscribedPtyIds',
        {'p2'},
      ),
    );

    host.completeReplay('p1');
    await _flushEffects();
    expect(host.synced.last, {'p2'});
  });

  test('mobile surface lifecycle is represented and awaited', () async {
    final host = _StreamHost(activePtyId: 'p1', liveTabPtyIds: {'p1'});
    final runtime = TerminalStreamRuntimeController(
      host: host,
      policy: TerminalStreamPlatformPolicy.mobile,
      onStateChanged: (_) {},
    );
    addTearDown(runtime.dispose);

    await runtime.surfaceReady('p1');
    expect(host.ensured, ['p1']);
    expect(runtime.state.mountedPtyIds, {'p1'});

    await runtime.surfaceDisposed('p1');
    expect(host.closed, ['p1']);
    expect(runtime.state.mountedPtyIds, isEmpty);
  });

  test('newest surface request owns pending state for one PTY', () async {
    final host = _StreamHost(activePtyId: 'p1', liveTabPtyIds: {'p1'})
      ..ensureGate = Completer<void>()
      ..closeGate = Completer<void>();
    final runtime = TerminalStreamRuntimeController(
      host: host,
      policy: TerminalStreamPlatformPolicy.mobile,
      onStateChanged: (_) {},
    );
    addTearDown(runtime.dispose);

    final mounted = runtime.surfaceReady('p1');
    final disposed = runtime.surfaceDisposed('p1');

    expect(runtime.state.operationSequence, 2);
    expect(runtime.state.pendingSurfacePtyIds, {'p1'});
    expect(runtime.state.mountedPtyIds, isEmpty);

    host.ensureGate!.complete();
    await mounted;
    await _waitFor(() => host.closed.isNotEmpty);
    expect(
      runtime.state.pendingSurfacePtyIds,
      {'p1'},
      reason: 'the queued dispose operation is still pending',
    );

    host.closeGate!.complete();
    await disposed;
    expect(runtime.state.pendingSurfacePtyIds, isEmpty);
  });
}

final class _StreamHost implements TerminalRuntimeHost {
  _StreamHost({required this.activePtyId, required this.liveTabPtyIds});

  @override
  String? activePtyId;

  @override
  Set<String> liveTabPtyIds;

  @override
  Set<String> terminalSurfacePtyIds = {};

  final List<String> ensured = [];
  final List<String> closed = [];
  final List<Set<String>> synced = [];
  final Map<String, Completer<void>> replays = {};
  Completer<void>? ensureGate;
  Completer<void>? closeGate;

  @override
  Future<void> ensurePtyStream(String ptyId) async {
    ensured.add(ptyId);
    await ensureGate?.future;
  }

  @override
  Future<void> closePtyStream(String ptyId) async {
    closed.add(ptyId);
    await closeGate?.future;
  }

  @override
  Future<void> syncPtyStreams(Set<String> ptyIds) async {
    synced.add(Set<String>.from(ptyIds));
  }

  @override
  Future<void> waitForPtyReplay(String ptyId) =>
      replays.putIfAbsent(ptyId, Completer<void>.new).future;

  void completeReplay(String ptyId) {
    final replay = replays.putIfAbsent(ptyId, Completer<void>.new);
    if (!replay.isCompleted) replay.complete();
  }
}

Future<void> _flushEffects() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 50 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
