import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/server/session_catalog_controller.dart';
import 'package:motif/motif/state/server/session_catalog_view_model.dart';

void main() {
  test('create sends an ordinary session payload', () async {
    final payloads = <Map<String, Object?>>[];
    final controller = SessionCatalogController(
      viewModel: SessionCatalogViewModel(sessions: ObservableList()),
      transport: SessionCatalogTransport(
        isAvailable: () => true,
        call: (method, [params = const {}]) async {
          expect(method, 'session.create');
          payloads.add(params);
          return {
            'session': {'name': params['name'], 'workdir': params['workdir']},
          };
        },
      ),
    )..refreshDelegate = () async {};

    final session = await controller.create('shell', '/tmp');

    expect(payloads, [
      {'name': 'shell', 'workdir': '/tmp'},
    ]);
    expect(session.name, 'shell');
    expect(session.workdir, '/tmp');
  });
}
