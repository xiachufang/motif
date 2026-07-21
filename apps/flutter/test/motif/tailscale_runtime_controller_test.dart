import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/platform/tailscale_models.dart';
import 'package:motif/motif/state/platform/tailscale_runtime_controller.dart';
import 'package:motif/motif/state/platform/tailscale_runtime_state.dart';

void main() {
  test('browser-auth progress and health are explicit child states', () async {
    final started = Completer<void>();
    var probes = 0;
    final controller = TailscaleRuntimeController(
      startNode: (_, context, onProgress) async {
        onProgress(
          const TailscaleState(
            TailscaleStatus.needsAuth,
            authUrl: 'https://login.example.test',
          ),
        );
        await started.future;
        return const TailscaleState(TailscaleStatus.running);
      },
      stopNode: (_) async {},
      probeHealth: (_) async {
        probes++;
        return const TailscaleHealthSample(
          state: TailscaleState(TailscaleStatus.running),
          backendState: 'Running',
        );
      },
      restartAuthKey: () => null,
      onStateChanged: (_) {},
      healthProbeInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);

    final start = controller.start();
    expect(controller.state.lifecycle, isA<TailscaleLifecycleNeedsAuth>());
    expect(
      (controller.state.lifecycle as TailscaleLifecycleNeedsAuth)
          .operationPending,
      isTrue,
    );

    started.complete();
    await start;
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.lifecycle, isA<TailscaleLifecycleRunning>());
    expect(controller.state.health, isA<TailscaleHealthMonitoring>());
    expect(probes, 1);
    final health = controller.state.health as TailscaleHealthMonitoring;
    expect(health.lastBackendState, 'Running');
  });

  test('stop invalidates a late start result', () async {
    final started = Completer<TailscaleState>();
    var stops = 0;
    final controller = TailscaleRuntimeController(
      startNode: (_, context, onProgress) => started.future,
      stopNode: (_) async {
        stops++;
      },
      probeHealth: (_) async => null,
      restartAuthKey: () => null,
      onStateChanged: (_) {},
    );
    addTearDown(controller.dispose);

    final start = controller.start(authKey: 'secret');
    final stop = controller.stop();
    await stop;
    started.complete(const TailscaleState(TailscaleStatus.running));
    await start;
    await Future<void>.delayed(Duration.zero);

    expect(stops, 1);
    expect(controller.state.lifecycle, isA<TailscaleLifecycleStopped>());
    expect(controller.state.health, isA<TailscaleHealthDormant>());
  });

  test(
    'degraded health restarts once and respects the restart window',
    () async {
      final probeGates = <Completer<TailscaleHealthSample?>>[];
      var starts = 0;
      var stops = 0;
      final now = DateTime(2026, 7, 21, 12);
      final controller = TailscaleRuntimeController(
        startNode: (_, context, onProgress) async {
          starts++;
          return const TailscaleState(TailscaleStatus.running);
        },
        stopNode: (_) async {
          stops++;
        },
        probeHealth: (_) {
          final gate = Completer<TailscaleHealthSample?>();
          probeGates.add(gate);
          return gate.future;
        },
        restartAuthKey: () => 'saved-secret',
        onStateChanged: (_) {},
        healthProbeInterval: Duration.zero,
        maxMissedHealthProbes: 1,
        maxConsecutiveDegradedProbes: 2,
        autoRestartMinInterval: const Duration(minutes: 2),
        now: () => now,
      );
      addTearDown(controller.dispose);

      await controller.start(authKey: 'saved-secret');
      await _waitFor(() => probeGates.length == 1);
      probeGates[0].complete(null);
      await _waitFor(() => probeGates.length == 2);
      probeGates[1].complete(null);
      await _waitFor(() => starts == 2 && probeGates.length == 3);

      expect(stops, 1);
      expect(controller.state.lastAutoRestartAt, now);
      expect(controller.state.lifecycle, isA<TailscaleLifecycleRunning>());

      probeGates[2].complete(null);
      await _waitFor(() => probeGates.length == 4);
      probeGates[3].complete(null);
      await _waitFor(() => probeGates.length == 5);

      expect(starts, 2, reason: 'the second degraded run is rate-limited');
      expect(stops, 1);
      expect(controller.state.lifecycle, isA<TailscaleLifecycleDegraded>());
      expect(
        (controller.state.health as TailscaleHealthMonitoring)
            .consecutiveDegradedProbes,
        2,
      );
    },
  );
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 50 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
