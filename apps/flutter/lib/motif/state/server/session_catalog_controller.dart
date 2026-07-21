import '../../models/motif_proto.dart';
import 'session_catalog_view_model.dart';

typedef SessionCatalogRpcCall =
    Future<Map<String, Object?>> Function(
      String method, [
      Map<String, Object?> params,
    ]);

final class SessionCatalogTransport {
  const SessionCatalogTransport({
    required this.isAvailable,
    required this.call,
  });

  final bool Function() isAvailable;
  final SessionCatalogRpcCall call;
}

typedef RemovedSession = ({int index, SessionInfo? session});

/// Server-scoped session catalog and commands.
final class SessionCatalogController {
  const SessionCatalogController({
    required this.viewModel,
    required this.transport,
  });

  final SessionCatalogViewModel viewModel;
  final SessionCatalogTransport transport;

  Future<void> refresh() async {
    if (!transport.isAvailable()) return;
    viewModel
      ..phase = SessionCatalogPhase.loading
      ..error = null;
    try {
      final body = await transport.call('session.list');
      final sessions = ((body['sessions'] as List?) ?? [])
          .map(
            (entry) =>
                SessionInfo.fromJson((entry as Map).cast<String, Object?>()),
          )
          .toList();
      viewModel.sessions.replaceRange(0, viewModel.sessions.length, sessions);
      viewModel
        ..phase = SessionCatalogPhase.ready
        ..lastUpdatedAt = DateTime.now();
    } catch (error) {
      viewModel
        ..phase = SessionCatalogPhase.failed
        ..error = '$error';
      rethrow;
    }
  }

  Future<SessionInfo> create(String name, String workdir) async {
    final body = await transport.call('session.create', {
      'name': name,
      'workdir': workdir,
    });
    await refresh();
    return SessionInfo.fromJson(
      (body['session'] as Map?)?.cast<String, Object?>() ?? {'name': name},
    );
  }

  RemovedSession removeOptimistically(String name) {
    final index = viewModel.sessions.indexWhere(
      (session) => session.name == name,
    );
    if (index < 0) return (index: index, session: null);
    return (index: index, session: viewModel.sessions.removeAt(index));
  }

  void restore(RemovedSession removed) {
    final session = removed.session;
    if (session == null ||
        viewModel.sessions.any((candidate) => candidate.name == session.name)) {
      return;
    }
    viewModel.sessions.insert(
      removed.index.clamp(0, viewModel.sessions.length).toInt(),
      session,
    );
  }

  Future<void> destroyRemote(String name) =>
      transport.call('session.destroy', {'name': name}).then((_) {});
}
