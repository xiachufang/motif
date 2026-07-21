import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/app/app_runtime_controller.dart';
import 'package:motif/motif/state/app/app_runtime_state.dart';

void main() {
  test(
    'embedded startup waits for readiness without blocking caller',
    () async {
      final connected = <String>[];
      late AppRuntimeState observed;
      final runtime = AppRuntimeController(
        connectStartupServer: (serverId) async {
          connected.add(serverId);
          return true;
        },
        applyLifecycle: (_) {},
        onStateChanged: (state) => observed = state,
      );
      addTearDown(runtime.dispose);

      await runtime.start(serverId: 'embedded', waitForEmbedded: true);

      expect(runtime.state.startup, isA<AppStartupWaitingEmbedded>());
      expect(connected, isEmpty);

      runtime.embeddedReady('embedded');
      await _flushEffects();

      expect(connected, ['embedded']);
      expect(runtime.state.startup, isA<AppStartupReady>());
      expect(observed.startup, isA<AppStartupReady>());
    },
  );

  test(
    'superseded startup result cannot overwrite the current intent',
    () async {
      final first = Completer<bool>();
      final second = Completer<bool>();
      final runtime = AppRuntimeController(
        connectStartupServer: (serverId) => switch (serverId) {
          'first' => first.future,
          'second' => second.future,
          _ => throw StateError('unexpected server $serverId'),
        },
        applyLifecycle: (_) {},
        onStateChanged: (_) {},
      );
      addTearDown(runtime.dispose);

      final firstStart = runtime.start(
        serverId: 'first',
        waitForEmbedded: false,
      );
      final secondStart = runtime.start(
        serverId: 'second',
        waitForEmbedded: false,
      );

      first.complete(true);
      await _flushEffects();
      expect(
        runtime.state.startup,
        isA<AppStartupConnecting>().having(
          (state) => state.serverId,
          'serverId',
          'second',
        ),
      );

      second.complete(true);
      await Future.wait([firstStart, secondStart]);
      await _flushEffects();
      expect(
        runtime.state.startup,
        isA<AppStartupReady>().having(
          (state) => state.serverId,
          'serverId',
          'second',
        ),
      );
    },
  );

  test(
    'repeated lifecycle events replay effects without changing state',
    () async {
      final lifecycleEvents = <bool>[];
      final runtime = AppRuntimeController(
        connectStartupServer: (_) async => true,
        applyLifecycle: lifecycleEvents.add,
        onStateChanged: (_) {},
      );
      addTearDown(runtime.dispose);

      runtime.setForeground(true);
      runtime.setForeground(true);
      await _flushEffects();

      expect(runtime.state.lifecycle, isA<AppRuntimeForeground>());
      // The keyed restartable effect coalesces immediately superseded callbacks.
      expect(lifecycleEvents, isNotEmpty);
      expect(lifecycleEvents.last, isTrue);

      runtime.setForeground(false);
      await _flushEffects();
      expect(runtime.state.lifecycle, isA<AppRuntimeBackground>());
      expect(lifecycleEvents.last, isFalse);
    },
  );
}

Future<void> _flushEffects() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
