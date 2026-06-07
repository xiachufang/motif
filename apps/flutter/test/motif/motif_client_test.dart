import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/motif_client.dart';

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
}

ViewInfo _view(String id) => ViewInfo(id: id, spec: PtyViewSpec('pty-$id'));
