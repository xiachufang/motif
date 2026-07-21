import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/server/device_controller.dart';
import 'package:motif/motif/state/server/device_registration_view_model.dart';

void main() {
  test('same-session mute queue keeps the newest operation pending', () async {
    final gates = <Completer<Map<String, Object?>>>[];
    final controller = DeviceController(
      viewModel: DeviceRegistrationViewModel(),
      transport: DeviceTransport(
        isAvailable: () => true,
        call: (method, [params = const {}]) {
          expect(method, 'device.set_session_muted');
          final gate = Completer<Map<String, Object?>>();
          gates.add(gate);
          return gate.future;
        },
      ),
    );
    addTearDown(controller.dispose);

    final first = controller.setSessionMuted(
      deviceToken: 'token',
      session: 'work',
      muted: true,
    );
    final second = controller.setSessionMuted(
      deviceToken: 'token',
      session: 'work',
      muted: false,
    );

    expect(gates, hasLength(1));
    expect(controller.runtimeState.operationSequence, 2);
    expect(controller.runtimeState.mutingSessions, {'work'});

    gates[0].complete(const {});
    await first;
    await _waitFor(() => gates.length == 2);
    expect(
      controller.runtimeState.mutingSessions,
      {'work'},
      reason: 'the newer queued operation still owns the pending state',
    );

    gates[1].complete(const {});
    await second;
    expect(controller.runtimeState.mutingSessions, isEmpty);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 50 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
