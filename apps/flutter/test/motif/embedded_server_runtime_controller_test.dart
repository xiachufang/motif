import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/embedded/embedded_server_models.dart';
import 'package:motif/motif/state/embedded/embedded_server_runtime_controller.dart';
import 'package:motif/motif/state/embedded/embedded_server_runtime_state.dart';

void main() {
  test('start and polling advance lifecycle without a service Timer', () async {
    final poll = Completer<EmbeddedServerStatus?>();
    final nextPoll = Completer<EmbeddedServerStatus?>();
    var probes = 0;
    EmbeddedServerStatus? projectedStatus;
    final controller = EmbeddedServerRuntimeController(
      available: true,
      startNative: (_) async => const EmbeddedServerStatus(starting: true),
      stopNative: (_) async => const EmbeddedServerStatus(),
      probeStatus: (_) => probes++ == 0 ? poll.future : nextPoll.future,
      writeConfig: (config, _) async => config,
      project: (state, {status, config}) {
        projectedStatus = status ?? projectedStatus;
      },
      pollInterval: Duration.zero,
    );
    addTearDown(controller.dispose);

    await controller.start();
    await _waitFor(() => controller.state.poll is EmbeddedServerPollScheduled);
    expect(controller.state.lifecycle, isA<EmbeddedServerStarting>());
    expect(projectedStatus?.starting, isTrue);

    poll.complete(
      const EmbeddedServerStatus(
        running: true,
        boundAddrs: ['tcp://127.0.0.1:7777'],
      ),
    );
    await _waitFor(() => controller.state.lifecycle is EmbeddedServerRunning);

    expect(projectedStatus?.running, isTrue);
    expect(controller.state.poll, isA<EmbeddedServerPollScheduled>());
  });

  test('stop cancels a late start and settles both callers', () async {
    final startGate = Completer<EmbeddedServerStatus>();
    var stops = 0;
    final controller = EmbeddedServerRuntimeController(
      available: true,
      startNative: (_) => startGate.future,
      stopNative: (_) async {
        stops++;
        return const EmbeddedServerStatus();
      },
      probeStatus: (_) async => null,
      writeConfig: (config, _) async => config,
      project: (state, {status, config}) {},
    );
    addTearDown(controller.dispose);

    final start = controller.start();
    final stop = controller.stop();
    await Future.wait([start, stop]);
    startGate.complete(const EmbeddedServerStatus(running: true));
    await Future<void>.delayed(Duration.zero);

    expect(stops, 1);
    expect(controller.state.lifecycle, isA<EmbeddedServerStopped>());
    expect(controller.state.poll, isA<EmbeddedServerPollDormant>());
  });

  test(
    'config writes stay ordered while the latest revision is visible',
    () async {
      final gates = <Completer<void>>[];
      final writes = <int>[];
      final projections = <int>[];
      final controller = EmbeddedServerRuntimeController(
        available: true,
        startNative: (_) async => const EmbeddedServerStatus(),
        stopNative: (_) async => const EmbeddedServerStatus(),
        probeStatus: (_) async => null,
        writeConfig: (config, _) async {
          writes.add(config.port);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return config;
        },
        project: (state, {status, config}) {
          if (config != null) projections.add(config.port);
        },
      );
      addTearDown(controller.dispose);

      final first = controller.updateConfig(
        const EmbeddedServerConfig(port: 7001),
      );
      final second = controller.updateConfig(
        const EmbeddedServerConfig(port: 7002),
      );

      expect(writes, [7001]);
      expect(controller.state.configWrite, isA<EmbeddedConfigSaving>());
      expect(controller.state.configWrite.revision, 2);

      gates[0].complete();
      await first;
      await _waitFor(() => writes.length == 2);
      expect(projections, [7001]);
      expect(controller.state.configWrite.revision, 2);

      gates[1].complete();
      await second;

      expect(writes, [7001, 7002]);
      expect(projections, [7001, 7002]);
      expect(controller.state.configWrite, isA<EmbeddedConfigIdle>());
      expect(controller.state.configWrite.revision, 2);
    },
  );
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 50 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
