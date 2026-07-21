import 'dart:async';

import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_controller.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_view_model.dart';
import 'package:motif/motif/state/workspace/terminal/terminal_runtime_policy.dart';

import 'support/workspace_connection_fixture.dart';

void main() {
  group('WorkspaceConnectionController state ownership', () {
    test('focused observable collections mutate independently', () {
      final motif = WorkspaceConnectionController(session: 'work');
      addTearDown(motif.dispose);
      const initialClients = [ClientInfo(id: 'client-1')];
      var commandChanges = 0;
      var clientChanges = 0;
      final subscription = observe(
        () => motif.terminal.viewModel.runningCommand['pty-1'],
        onChange: (_) => commandChanges++,
        scheduler: ObservationSchedulers.immediate,
      );
      addTearDown(subscription.dispose);
      final clientSubscription = observe(
        () => motif.presence.clients.length,
        onChange: (_) => clientChanges++,
        scheduler: ObservationSchedulers.immediate,
      );
      addTearDown(clientSubscription.dispose);

      motif.presence.clients.addAll(initialClients);
      motif.presence.clients.add(const ClientInfo(id: 'client-2'));
      motif.runningCommand['pty-1'] = 'dart test';

      expect(motif.presence.clients, isA<ObservableList<ClientInfo>>());
      expect(motif.presence.clients.map((client) => client.id), [
        'client-1',
        'client-2',
      ]);
      expect(
        motif.runningCommand,
        same(motif.terminal.viewModel.runningCommand),
      );
      expect(motif.terminal.viewModel.runningCommand['pty-1'], 'dart test');
      expect(clientChanges, 2);
      expect(commandChanges, 1);
    });
  });

  group('WorkspaceConnectionController view ordering', () {
    test('moveView reorders views locally while offline', () async {
      final motif = WorkspaceConnectionController(session: 'work');
      addTearDown(motif.dispose);
      motif.views = [_view('v1'), _view('v2'), _view('v3')];

      var notifications = 0;
      final subscription = observe(
        () => motif.views.map((view) => view.id).toList(),
        onChange: (_) => notifications++,
        scheduler: ObservationSchedulers.immediate,
      );
      addTearDown(subscription.dispose);

      await motif.viewsController.move('v1', 2);

      expect(motif.views.map((v) => v.id), ['v2', 'v3', 'v1']);
      expect(notifications, 1);
    });

    test('moveView clamps target index and ignores unknown views', () async {
      final motif = WorkspaceConnectionController(session: 'work');
      addTearDown(motif.dispose);
      motif.views = [_view('v1'), _view('v2'), _view('v3')];

      await motif.viewsController.move('v3', -10);
      expect(motif.views.map((v) => v.id), ['v3', 'v1', 'v2']);

      await motif.viewsController.move('missing', 1);
      expect(motif.views.map((v) => v.id), ['v3', 'v1', 'v2']);
    });
  });

  group('WorkspaceConnectionController runtime', () {
    test('desktop keeps all live tab pty streams live', () async {
      final runtime = DesktopTerminalRuntimePolicy(
        backgroundRestoreDelay: Duration.zero,
      );
      final host = _RuntimeHost(
        liveTabPtyIds: {'pty-1', 'pty-2'},
        activePtyId: 'pty-1',
      );

      runtime.onSessionAttached(host);
      await Future<void>.delayed(Duration.zero);
      expect(host.syncedStreamSets, [
        {'pty-1'},
      ]);

      host.completeReplay('pty-1');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(host.syncedStreamSets, [
        {'pty-1'},
        {'pty-1', 'pty-2'},
      ]);

      await runtime.onTerminalSurfaceDisposed(host, 'pty-1');

      expect(host.closedPtys, isEmpty);
      expect(host.syncedStreamSets, [
        {'pty-1'},
        {'pty-1', 'pty-2'},
      ]);
    });

    test('mobile leaves pty streams to terminal surface lifecycle', () async {
      final runtime = MobileTerminalRuntimePolicy();
      final host = _RuntimeHost(
        liveTabPtyIds: {'pty-1', 'pty-2'},
        activePtyId: 'pty-1',
      );

      runtime.onSessionAttached(host);
      await Future<void>.delayed(Duration.zero);
      expect(host.syncedStreamSets, isEmpty);

      await runtime.onTerminalSurfaceReady(host, 'pty-1');
      expect(host.ensuredPtys, ['pty-1']);

      await runtime.onTerminalSurfaceDisposed(host, 'pty-1');
      expect(host.closedPtys, ['pty-1']);
    });

    test('mobile restores mounted terminal stream after reattach', () async {
      final runtime = MobileTerminalRuntimePolicy();
      final host = _RuntimeHost(
        liveTabPtyIds: {'pty-1', 'pty-2'},
        activePtyId: 'pty-1',
        terminalSurfacePtyIds: {'pty-1', 'stale-pty'},
      );

      runtime.onSessionAttached(host);
      await Future<void>.delayed(Duration.zero);

      expect(host.ensuredPtys, ['pty-1']);
    });

    test('liveTabPtyIds follows terminal tabs and alive state', () {
      final motif = WorkspaceConnectionController(session: 'work');
      addTearDown(motif.dispose);
      motif.ptys = const [
        PtyInfo(id: 'pty-1', cols: 80, rows: 24),
        PtyInfo(id: 'pty-2', cols: 80, rows: 24, alive: false),
      ];
      motif.views = const [
        ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1')),
        ViewInfo(id: 'v2', spec: PtyViewSpec('pty-2')),
        ViewInfo(id: 'v3', spec: PreviewViewSpec('/tmp/file.txt')),
        ViewInfo(id: 'v4', spec: PtyViewSpec('pty-missing')),
      ];

      expect(motif.terminal.liveTabPtyIds, {'pty-1', 'pty-missing'});
    });

    test(
      'workspace keeps its fixed session identity when disconnected',
      () async {
        final motif = WorkspaceConnectionController(session: 'work');
        addTearDown(motif.dispose);
        motif
          ..ptys = const [PtyInfo(id: 'pty-1', cols: 80, rows: 24)]
          ..views = const [ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1'))]
          ..activeViewId = 'v1';

        await motif.disconnect();

        expect(motif.session, 'work');
        expect(motif.state, isA<ConnDisconnected>());
        expect(motif.ptys, isEmpty);
        expect(motif.views, isEmpty);
        expect(motif.activeViewId, isNull);
      },
    );

    test('closing a view immediately updates pty subscriptions', () async {
      final runtime = _RecordingRuntime();
      final motif = WorkspaceConnectionController(
        session: 'work',
        runtime: runtime,
      );
      addTearDown(motif.dispose);
      motif.ptys = const [
        PtyInfo(id: 'pty-1', cols: 80, rows: 24),
        PtyInfo(id: 'pty-2', cols: 80, rows: 24),
      ];
      motif.views = const [
        ViewInfo(id: 'v1', spec: PtyViewSpec('pty-1')),
        ViewInfo(id: 'v2', spec: PtyViewSpec('pty-2')),
      ];
      motif.activeViewId = 'v1';

      await motif.viewsController.close('v1');

      expect(runtime.subscriptionSets, [
        {'pty-2'},
      ]);
    });
  });
}

ViewInfo _view(String id) => ViewInfo(id: id, spec: PtyViewSpec('pty-$id'));

class _RuntimeHost implements TerminalRuntimeHost {
  _RuntimeHost({
    required this.liveTabPtyIds,
    required this.activePtyId,
    this.terminalSurfacePtyIds = const {},
  });

  @override
  final Set<String> liveTabPtyIds;

  @override
  final String? activePtyId;

  @override
  final Set<String> terminalSurfacePtyIds;

  final List<String> ensuredPtys = [];
  final List<String> closedPtys = [];
  final List<Set<String>> syncedStreamSets = [];
  final Map<String, Completer<void>> replayCompleters = {};

  @override
  Future<void> ensurePtyStream(String ptyId) async {
    ensuredPtys.add(ptyId);
  }

  @override
  Future<void> closePtyStream(String ptyId) async {
    closedPtys.add(ptyId);
  }

  @override
  Future<void> syncPtyStreams(Set<String> ptyIds) async {
    syncedStreamSets.add(Set<String>.from(ptyIds));
  }

  @override
  Future<void> waitForPtyReplay(String ptyId) =>
      replayCompleters.putIfAbsent(ptyId, Completer<void>.new).future;

  void completeReplay(String ptyId) {
    final completer = replayCompleters.putIfAbsent(ptyId, Completer<void>.new);
    if (!completer.isCompleted) completer.complete();
  }
}

class _RecordingRuntime implements TerminalRuntimePolicy {
  final List<Set<String>> subscriptionSets = [];

  @override
  void onSessionAttached(TerminalRuntimeHost client) {}

  @override
  void onPtySubscriptionsChanged(TerminalRuntimeHost client) {
    subscriptionSets.add(Set<String>.from(client.liveTabPtyIds));
  }

  @override
  void onActiveViewChanged(TerminalRuntimeHost client) {}

  @override
  Future<void> onTerminalSurfaceReady(
    TerminalRuntimeHost client,
    String ptyId,
  ) async {}

  @override
  Future<void> onTerminalSurfaceDisposed(
    TerminalRuntimeHost client,
    String ptyId,
  ) async {}
}
