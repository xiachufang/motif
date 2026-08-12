import 'package:flutter/widgets.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../codex/codex_state.dart';
import '../../session/session_feature_runtime.dart';
import '../../ui/integration/app_session_runtime.dart';
import '../../update/desktop_update_service.dart';
export '../dependency_scope.dart';

import 'app_state.dart';
import '../embedded/embedded_server_service.dart';

/// Injects Motif's process-wide dependencies through Observation scopes.
///
/// The scopes only expose existing instances. Ownership and disposal remain
/// with the bootstrap/runtime that created them.
final class MotifScope extends StatefulWidget {
  const MotifScope({
    required this.appState,
    required this.child,
    this.codexState,
    this.embeddedServer,
    this.desktopUpdateService,
    super.key,
  });

  final AppState appState;
  final CodexState? codexState;
  final EmbeddedServerService? embeddedServer;
  final DesktopUpdateService? desktopUpdateService;
  final Widget child;

  @override
  State<MotifScope> createState() => _MotifScopeState();
}

final class _MotifScopeState extends State<MotifScope> {
  late final CodexState _fallbackCodexState = CodexState();
  late AppSessionRuntime _sessionRuntime = AppSessionRuntime(widget.appState);

  @override
  void didUpdateWidget(covariant MotifScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.appState, widget.appState)) {
      _sessionRuntime = AppSessionRuntime(widget.appState);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget scoped = ObservationScope<DesktopUpdateService?>(
      value: widget.desktopUpdateService,
      child: widget.child,
    );
    final server = widget.embeddedServer ?? widget.appState.embeddedServer;
    if (server != null) {
      scoped = ObservationScope<EmbeddedServerService>(
        value: server,
        child: scoped,
      );
    }
    scoped = ObservationScope<CodexState>(
      value: widget.codexState ?? _fallbackCodexState,
      child: scoped,
    );
    scoped = ObservationScope<SessionFeatureRuntime>(
      value: _sessionRuntime,
      child: scoped,
    );
    return ObservationScope<AppState>(value: widget.appState, child: scoped);
  }
}
