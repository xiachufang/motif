import 'dart:async';

import 'device_controller.dart';
import 'server_access_controller.dart';
import 'server_transport.dart';
import 'server_view_models.dart';
import 'session_catalog_controller.dart';
import '../workspace/workspace_api.dart';

/// Runtime resources owned by one configured server.
final class ServerInstance {
  const ServerInstance({
    required this.viewModel,
    required this.transport,
    required this.access,
    required this.sessions,
    required this.device,
    required this.workspace,
  });

  final ServerViewModel viewModel;
  final ServerTransport transport;
  final ServerAccessController access;
  final SessionCatalogController sessions;
  final DeviceController device;

  /// Unattached filesystem capability used only by server-level flows such as
  /// choosing a working directory while creating a Session.
  final WorkspaceApi workspace;

  String get id => viewModel.id;
  bool get isLive => transport.isLive;

  Future<void> close() => access.disconnect();

  void dispose() {
    access.dispose();
    unawaited(transport.close());
  }
}
