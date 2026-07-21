import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/workspace/remote_port/remote_port_runtime.dart';

void main() {
  test('operations execute serially and expose queued control state', () async {
    final firstGate = Completer<void>();
    final calls = <String>[];
    final runtime = RemotePortRuntimeController(onStateChanged: (_) {});
    addTearDown(runtime.dispose);

    final first = runtime.run(RemotePortOperationKind.refresh, () async {
      calls.add('first');
      await firstGate.future;
      return 1;
    });
    final second = runtime.run(RemotePortOperationKind.add, () async {
      calls.add('second');
      return 2;
    });

    expect(calls, ['first']);
    expect(
      runtime.state,
      isA<RemotePortRuntimeRunning>().having(
        (state) => state.queued.length,
        'queued.length',
        1,
      ),
    );
    expect(runtime.state.requestSequence, 2);

    firstGate.complete();
    expect(await first, 1);
    expect(await second, 2);
    expect(calls, ['first', 'second']);
    expect(runtime.state, isA<RemotePortRuntimeReady>());
  });

  test('a failed operation does not strand the queued operation', () async {
    final runtime = RemotePortRuntimeController(onStateChanged: (_) {});
    addTearDown(runtime.dispose);

    final failed = runtime.run<void>(RemotePortOperationKind.remove, () async {
      throw StateError('failed');
    });
    final next = runtime.run(RemotePortOperationKind.refresh, () async => 42);

    await expectLater(failed, throwsStateError);
    expect(await next, 42);
    expect(runtime.state, isA<RemotePortRuntimeReady>());
  });
}
