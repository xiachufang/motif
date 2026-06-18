import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/state/motif_runtime.dart';

void main() {
  group('MotifClient view ordering', () {
    test('moveView reorders views locally while offline', () async {
      final motif = MotifClient();
      addTearDown(motif.dispose);
      motif.views = [_view('v1'), _view('v2'), _view('v3')];

      var notifications = 0;
      motif.addListener(() => notifications++);

      await motif.moveView('v1', 2);

      expect(motif.views.map((v) => v.id), ['v2', 'v3', 'v1']);
      expect(notifications, 1);
    });

    test('moveView clamps target index and ignores unknown views', () async {
      final motif = MotifClient();
      addTearDown(motif.dispose);
      motif.views = [_view('v1'), _view('v2'), _view('v3')];

      await motif.moveView('v3', -10);
      expect(motif.views.map((v) => v.id), ['v3', 'v1', 'v2']);

      await motif.moveView('missing', 1);
      expect(motif.views.map((v) => v.id), ['v3', 'v1', 'v2']);
    });
  });

  group('MotifClient runtime', () {
    test('desktop keeps all live tab pty streams live', () async {
      final runtime = DesktopMotifClientRuntime();
      final host = _RuntimeHost(
        liveTabPtyIds: {'pty-1', 'pty-2'},
        activePtyId: 'pty-1',
      );

      runtime.onSessionAttached(host);
      await Future<void>.delayed(Duration.zero);

      expect(host.syncedStreamSets, [
        {'pty-1', 'pty-2'},
      ]);

      await runtime.onTerminalSurfaceDisposed(host, 'pty-1');

      expect(host.closedPtys, isEmpty);
      expect(host.syncedStreamSets, [
        {'pty-1', 'pty-2'},
      ]);
    });

    test('mobile leaves pty streams to terminal surface lifecycle', () async {
      final runtime = MobileMotifClientRuntime();
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

    test('liveTabPtyIds follows terminal tabs and alive state', () {
      final motif = MotifClient();
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

      expect(motif.liveTabPtyIds, {'pty-1', 'pty-missing'});
    });

    test('closing a view immediately updates pty subscriptions', () async {
      final runtime = _RecordingRuntime();
      final motif = MotifClient(runtime: runtime);
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

      await motif.closeView('v1');

      expect(runtime.subscriptionSets, [
        {'pty-2'},
      ]);
    });
  });
}

ViewInfo _view(String id) => ViewInfo(id: id, spec: PtyViewSpec('pty-$id'));

class _RuntimeHost implements MotifRuntimeClient {
  _RuntimeHost({required this.liveTabPtyIds, required this.activePtyId});

  @override
  final Set<String> liveTabPtyIds;

  @override
  final String? activePtyId;

  final List<String> ensuredPtys = [];
  final List<String> closedPtys = [];
  final List<Set<String>> syncedStreamSets = [];

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
}

class _RecordingRuntime implements MotifClientRuntime {
  final List<Set<String>> subscriptionSets = [];

  @override
  void onSessionAttached(MotifRuntimeClient client) {}

  @override
  void onPtySubscriptionsChanged(MotifRuntimeClient client) {
    subscriptionSets.add(Set<String>.from(client.liveTabPtyIds));
  }

  @override
  void onActiveViewChanged(MotifRuntimeClient client) {}

  @override
  Future<void> onTerminalSurfaceReady(
    MotifRuntimeClient client,
    String ptyId,
  ) async {}

  @override
  Future<void> onTerminalSurfaceDisposed(
    MotifRuntimeClient client,
    String ptyId,
  ) async {}
}
