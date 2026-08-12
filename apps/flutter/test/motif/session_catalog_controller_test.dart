import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/server/session_catalog_controller.dart';
import 'package:motif/motif/state/server/session_catalog_view_model.dart';

void main() {
  test('terminal create omits type while codex sends it', () async {
    final payloads = <Map<String, Object?>>[];
    final controller = SessionCatalogController(
      viewModel: SessionCatalogViewModel(sessions: ObservableList()),
      transport: SessionCatalogTransport(
        isAvailable: () => true,
        call: (method, [params = const {}]) async {
          expect(method, 'session.create');
          payloads.add(params);
          return {
            'session': {
              'name': params['name'],
              'workdir': params['workdir'],
              if (params['type'] != null) 'type': params['type'],
            },
          };
        },
      ),
    )..refreshDelegate = () async {};

    final terminal = await controller.create('shell', '/tmp');
    final codex = await controller.create(
      'agent',
      null,
      type: SessionType.codex,
    );

    expect(payloads, [
      {'name': 'shell', 'workdir': '/tmp'},
      {'name': 'agent', 'type': 'codex'},
    ]);
    expect(terminal.type, SessionType.terminal);
    expect(codex.type, SessionType.codex);
  });
}
