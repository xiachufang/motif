import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/workspace/connection/workspace_attachment_runtime.dart';

void main() {
  test('concurrent attach callers join one runtime effect', () async {
    final operation = Completer<void>();
    var calls = 0;
    final runtime = WorkspaceAttachmentRuntimeController(
      performAttach: () {
        calls++;
        return operation.future;
      },
      performRecovery: (_) async {},
      currentRpcSessionId: () => 'rpc-session',
      onStateChanged: (_) {},
    );
    addTearDown(runtime.dispose);

    final first = runtime.attach();
    final second = runtime.attach();

    expect(calls, 1);
    expect(runtime.state, isA<WorkspaceAttachmentAttaching>());

    operation.complete();
    await Future.wait([first, second]);

    expect(calls, 1);
    expect(
      runtime.state,
      isA<WorkspaceAttachmentAttached>().having(
        (state) => state.rpcSessionId,
        'rpcSessionId',
        'rpc-session',
      ),
    );
  });

  test('reset invalidates a stale attach completion', () async {
    final operation = Completer<void>();
    final runtime = WorkspaceAttachmentRuntimeController(
      performAttach: () => operation.future,
      performRecovery: (_) async {},
      currentRpcSessionId: () => 'stale-session',
      onStateChanged: (_) {},
    );
    addTearDown(runtime.dispose);

    final pending = runtime.attach();
    runtime.reset();
    await pending;
    operation.complete();
    await _flushEffects();

    expect(runtime.state, isA<WorkspaceAttachmentDetached>());
  });

  test('expired attachment recovery is single-flight', () async {
    final operation = Completer<void>();
    var calls = 0;
    final runtime = WorkspaceAttachmentRuntimeController(
      performAttach: () async {},
      performRecovery: (expiredSessionId) {
        expect(expiredSessionId, 'expired');
        calls++;
        return operation.future;
      },
      currentRpcSessionId: () => 'replacement',
      onStateChanged: (_) {},
    );
    addTearDown(runtime.dispose);

    final first = runtime.recover('expired');
    final second = runtime.recover('expired');
    expect(calls, 1);

    operation.complete();
    await Future.wait([first, second]);

    expect(calls, 1);
    expect(runtime.state, isA<WorkspaceAttachmentAttached>());
  });
}

Future<void> _flushEffects() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
