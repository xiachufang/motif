import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../codex/codex_connection_controller.dart';
import '../../codex/codex_feature_controller.dart';
import '../../codex/codex_navigation.dart';
import '../../codex/codex_state.dart';
import '../../models/motif_proto.dart';
import '../../state/app/app_state.dart';
import '../../state/dependency_scope.dart';
import '../../state/server/server_transport.dart';
import '../screens/codex_screen.dart';
import '../screens/session_screen.dart';

/// App composition boundary for Codex. The feature receives only its own
/// controller and emits workspace requests back through a callback.
final class AppCodexScreen extends StatefulWidget {
  const AppCodexScreen({
    required this.serverId,
    this.initialThreadId,
    super.key,
  });

  final String serverId;
  final String? initialThreadId;

  @override
  State<AppCodexScreen> createState() => _AppCodexScreenState();
}

final class _AppCodexScreenState extends State<AppCodexScreen> {
  CodexFeatureController? _controller;
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final app = readObservationScope<AppState>(context);
    final preferences = readObservationScope<CodexState>(context);
    _app = app;
    _controller = CodexFeatureController(
      serverId: widget.serverId,
      preferences: preferences,
      connectionFactory: () => _createConnection(app),
      controlService: (action) => _controlService(app, action),
      initialThreadId: widget.initialThreadId,
    );
  }

  CodexAppServerClient _createConnection(AppState app) {
    final serverTransport = app.serverInstance(widget.serverId).transport;
    if (serverTransport is! PoolServerTransport) {
      throw const ServerTransportException(
        'This server transport cannot open Codex.',
      );
    }
    return CodexConnectionController(
      transport: RpcCodexTransport(serverTransport.pool),
    );
  }

  Future<void> _controlService(AppState app, CodexServiceAction action) async {
    final method = switch (action) {
      CodexServiceAction.restart => 'codex.restart',
      CodexServiceAction.stop => 'codex.stop',
    };
    final body = await app
        .serverInstance(widget.serverId)
        .transport
        .call(method);
    final closed = (body['closed_sessions'] as List? ?? const [])
        .whereType<String>();
    await app.discardWorkspaces(widget.serverId, closed);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final app = _app;
    if (controller == null || app == null) {
      return const SizedBox.shrink();
    }
    return CodexScreen(
      controller: controller,
      onWorkspaceRequested: (request) => CodexSessionCoordinator.open(
        context,
        app: app,
        serverId: widget.serverId,
        request: request,
      ),
    );
  }
}

/// The sole bridge from Codex's explicit workspace action into Session.
///
/// File, image, and turn-diff navigation stays inside the Codex navigator and
/// never reaches this coordinator.
abstract final class CodexSessionCoordinator {
  static Future<void> open(
    BuildContext context, {
    required AppState app,
    required String serverId,
    required CodexWorkspaceRequest request,
  }) async {
    final body = await app.serverInstance(serverId).transport.call(
      'codex.workspace.ensure',
      {'thread_id': request.threadId, 'cwd': request.cwd},
    );
    final session = SessionInfo.fromJson(
      (body['session'] as Map).cast<String, Object?>(),
    );
    app.workspaceForSession(serverId, session.name);
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: RouteSettings(
          name: 'codex-workspace/$serverId/${request.threadId}',
        ),
        builder: (_) => SessionScreen(
          serverId: serverId,
          session: session.name,
          allowSessionSwitching: false,
          titleOverride: request.title,
        ),
      ),
    );
  }
}
