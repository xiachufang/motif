import 'dart:async';

import 'package:flutter/material.dart';

import '../../codex/codex_connection_controller.dart';
import '../../codex/codex_session_state.dart';
import '../../codex/codex_state.dart';
import '../../models/motif_proto.dart';
import '../../platform/window_title.dart';
import '../../state/app/app_state.dart';
import '../../state/app/motif_scope.dart';
import '../../state/server/server_transport.dart';
import '../theme/motif_theme.dart';
import '../widgets/observation_select.dart';
import 'codex_thread_sidebar.dart';
import 'codex_thread_workspace.dart';
import 'session_screen.dart';

typedef CodexControllerFactory =
    CodexConnectionController Function(
      AppState app,
      String serverId,
      String session,
    );
typedef CodexSessionStateFactory =
    CodexSessionState Function(AppState app, String serverId, String session);

class CodexSessionScreen extends StatefulWidget {
  const CodexSessionScreen({
    required this.serverId,
    required this.session,
    this.controllerFactory,
    this.sessionStateFactory,
    super.key,
  });

  final String serverId;
  final String session;
  final CodexControllerFactory? controllerFactory;
  final CodexSessionStateFactory? sessionStateFactory;

  @override
  State<CodexSessionScreen> createState() => _CodexSessionScreenState();
}

class _CodexSessionScreenState extends State<CodexSessionScreen> {
  static const double _mobileBreakpoint = 768;
  static const double _sidebarMinWidth = 260;
  static const double _resizeHandleWidth = 8;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  CodexSessionState? _sessionState;
  String? _setupError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sessionState != null || _setupError != null) return;
    try {
      final app = readObservationScope<AppState>(context);
      final factory = widget.sessionStateFactory;
      final sessionState = factory != null
          ? factory(app, widget.serverId, widget.session)
          : CodexSessionState(
              serverId: widget.serverId,
              session: widget.session,
              connection: _createController(app),
            );
      _sessionState = sessionState;
      sessionState.addListener(_changed);
      unawaited(sessionState.start());
      unawaited(
        MotifWindowTitle.set(
          '${widget.session} — Codex — Motif',
        ).catchError((_) {}),
      );
    } catch (error) {
      _setupError = error.toString();
    }
  }

  CodexConnectionController _createController(AppState app) {
    final factory = widget.controllerFactory;
    if (factory != null) {
      return factory(app, widget.serverId, widget.session);
    }
    final transport = app.serverInstance(widget.serverId).transport;
    if (transport is! RpcServerTransport) {
      throw const ServerTransportException(
        'This server transport cannot open Codex sessions.',
      );
    }
    return CodexConnectionController(
      session: widget.session,
      transport: RpcCodexSessionTransport(transport),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final sessionState = _sessionState;
    sessionState?.removeListener(_changed);
    sessionState?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = readObservationScope<AppState>(context);
    final codex = readObservationScope<CodexState>(context);
    final sessionState = _sessionState;
    return ObservationSelect<
      ({CodexSidebarMode mode, bool visible, double width})
    >(
      selector: () => (
        mode: codex.sidebarMode,
        visible: codex.desktopSidebarVisible,
        width: codex.sidebarWidth,
      ),
      builder: (context, chrome, _) => LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < _mobileBreakpoint;
          final canPop = Navigator.of(context).canPop();
          final sidebarToggle = IconButton(
            key: const ValueKey('codex-sidebar-toggle'),
            tooltip: mobile
                ? 'Open thread sidebar'
                : chrome.visible
                ? 'Hide thread sidebar'
                : 'Show thread sidebar',
            onPressed: () {
              if (mobile) {
                _scaffoldKey.currentState?.openDrawer();
              } else {
                codex.desktopSidebarVisible = !chrome.visible;
              }
            },
            icon: Icon(
              mobile || !chrome.visible
                  ? Icons.menu_rounded
                  : Icons.menu_open_rounded,
            ),
          );
          return Scaffold(
            key: _scaffoldKey,
            appBar: AppBar(
              leadingWidth: canPop ? 96 : null,
              leading: canPop
                  ? Row(children: [const BackButton(), sidebarToggle])
                  : sidebarToggle,
              title: Text(widget.session),
              actions: [_sessionSwitcher(app)],
            ),
            drawer: mobile && sessionState != null
                ? Drawer(
                    width: (constraints.maxWidth * 0.88)
                        .clamp(_sidebarMinWidth, 360)
                        .toDouble(),
                    child: _sidebar(
                      sessionState,
                      chrome.mode,
                      codex,
                      mobile: true,
                    ),
                  )
                : null,
            body: _setupError != null
                ? _MainSurface(child: _Failure(error: _setupError!))
                : sessionState == null
                ? const _MainSurface(child: CircularProgressIndicator())
                : MotifValueScope<CodexSessionState>(
                    value: sessionState,
                    child: mobile
                        ? _mainContent(sessionState)
                        : _desktopBody(
                            constraints,
                            sessionState,
                            codex,
                            chrome,
                          ),
                  ),
          );
        },
      ),
    );
  }

  Widget _desktopBody(
    BoxConstraints constraints,
    CodexSessionState sessionState,
    CodexState codex,
    ({CodexSidebarMode mode, bool visible, double width}) chrome,
  ) {
    final maxWidth = constraints.maxWidth * 0.6;
    final width = chrome.width.clamp(_sidebarMinWidth, maxWidth).toDouble();
    return Row(
      children: [
        if (chrome.visible) ...[
          SizedBox(
            key: const ValueKey('codex-desktop-sidebar'),
            width: width,
            child: _sidebar(sessionState, chrome.mode, codex, mobile: false),
          ),
          _SidebarResizeHandle(
            onDragDelta: (delta) {
              codex.sidebarWidth = (width + delta)
                  .clamp(_sidebarMinWidth, maxWidth)
                  .toDouble();
            },
          ),
        ],
        Expanded(child: _mainContent(sessionState)),
      ],
    );
  }

  Widget _sidebar(
    CodexSessionState sessionState,
    CodexSidebarMode mode,
    CodexState codex, {
    required bool mobile,
  }) => CodexThreadSidebar(
    sessionState: sessionState,
    mode: mode,
    onModeChanged: (value) => codex.sidebarMode = value,
    onThreadSelected: (threadId) {
      if (mobile && _scaffoldKey.currentState?.isDrawerOpen == true) {
        Navigator.of(context).pop();
      }
      unawaited(sessionState.readThread(threadId));
    },
  );

  Widget _mainContent(CodexSessionState state) {
    final connection = state.connectionState;
    return switch (connection.phase) {
      CodexConnectionPhase.connecting => const _MainSurface(
        child: _Progress(
          key: ValueKey('codex-connecting'),
          title: 'Connecting to Codex',
        ),
      ),
      CodexConnectionPhase.initializing => const _MainSurface(
        child: _Progress(
          key: ValueKey('codex-initializing'),
          title: 'Initializing experimental API',
        ),
      ),
      CodexConnectionPhase.connected =>
        state.readingThreadId != null
            ? const _MainSurface(
                child: _Progress(
                  key: ValueKey('codex-thread-loading'),
                  title: 'Loading thread',
                ),
              )
            : state.selectedThread == null
            ? _MainSurface(
                child: _Connected(state: connection, sessionState: state),
              )
            : CodexThreadWorkspace(state: state),
      CodexConnectionPhase.failed => _MainSurface(
        child: _Failure(
          error: connection.error ?? 'Connection failed',
          onRetry: state.retryConnection,
        ),
      ),
    };
  }

  Widget _sessionSwitcher(AppState app) =>
      PopupMenuButton<({String serverId, SessionInfo session})>(
        key: const ValueKey('codex-session-switcher'),
        tooltip: 'Switch session',
        icon: const Icon(Icons.swap_horiz_rounded),
        itemBuilder: (_) => [
          for (final group in app.connectedServerCapabilities)
            for (final session in group.viewModel.sessions.sessions)
              PopupMenuItem(
                value: (serverId: group.viewModel.id, session: session),
                child: Text(
                  '${group.viewModel.profile.name} / ${session.displayName}',
                ),
              ),
        ],
        onSelected: (target) => _switchSession(app, target),
      );

  void _switchSession(
    AppState app,
    ({String serverId, SessionInfo session}) target,
  ) {
    if (target.serverId == widget.serverId &&
        target.session.name == widget.session) {
      return;
    }
    unawaited(app.servers.setActive(target.serverId));
    if (target.session.type == SessionType.terminal) {
      app.workspaceForSession(target.serverId, target.session.name);
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        settings: RouteSettings(
          name: sessionRouteName(target.serverId, target.session.name),
        ),
        builder: (_) => target.session.type == SessionType.codex
            ? CodexSessionScreen(
                serverId: target.serverId,
                session: target.session.name,
              )
            : SessionScreen(
                serverId: target.serverId,
                session: target.session.name,
              ),
      ),
    );
  }
}

class _SidebarResizeHandle extends StatelessWidget {
  const _SidebarResizeHandle({required this.onDragDelta});

  final ValueChanged<double> onDragDelta;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        key: const ValueKey('codex-sidebar-resize-handle'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDragDelta(details.delta.dx),
        child: SizedBox(
          width: _CodexSessionScreenState._resizeHandleWidth,
          child: Center(child: Container(width: 1, color: c.border)),
        ),
      ),
    );
  }
}

class _MainSurface extends StatelessWidget {
  const _MainSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey('codex-main-surface'),
      color: context.motif.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(MotifSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.title, super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: c.accent),
        const SizedBox(height: MotifSpacing.lg),
        Text(title, style: MotifType.title.copyWith(color: c.textPrimary)),
      ],
    );
  }
}

class _Connected extends StatelessWidget {
  const _Connected({required this.state, required this.sessionState});

  final CodexConnectionState state;
  final CodexSessionState sessionState;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final response = state.response!;
    return Column(
      key: const ValueKey('codex-connected'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.check_circle_outline, size: 44, color: c.success),
        const SizedBox(height: MotifSpacing.md),
        Text(
          'Codex connected',
          textAlign: TextAlign.center,
          style: MotifType.title.copyWith(color: c.textPrimary),
        ),
        const SizedBox(height: MotifSpacing.sm),
        Text(
          sessionState.readingThreadId != null
              ? 'Reading thread…'
              : sessionState.catalogPhase == CodexCatalogPhase.failed
              ? 'Connected, but the thread catalog could not be loaded.'
              : 'Choose a thread from the sidebar.',
          textAlign: TextAlign.center,
          style: MotifType.subhead.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: MotifSpacing.xl),
        _Detail(label: 'User agent', value: response.userAgent),
        _Detail(label: 'Platform family', value: response.platformFamily),
        _Detail(label: 'Operating system', value: response.platformOs),
        if (sessionState.readError != null) ...[
          const SizedBox(height: MotifSpacing.lg),
          Text(
            sessionState.readError!,
            textAlign: TextAlign.center,
            style: MotifType.subhead.copyWith(color: c.danger),
          ),
          const SizedBox(height: MotifSpacing.sm),
          Center(
            child: OutlinedButton.icon(
              onPressed: () => unawaited(sessionState.retryRead()),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry thread'),
            ),
          ),
        ],
      ],
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MotifSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: MotifType.subhead.copyWith(color: c.textSecondary),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: MotifType.monoSmall.copyWith(color: c.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.error, this.onRetry});
  final String error;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Column(
      key: const ValueKey('codex-failed'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, size: 44, color: c.danger),
        const SizedBox(height: MotifSpacing.md),
        Text(
          'Codex connection failed',
          style: MotifType.title.copyWith(color: c.textPrimary),
        ),
        const SizedBox(height: MotifSpacing.sm),
        Text(
          error,
          textAlign: TextAlign.center,
          style: MotifType.subhead.copyWith(color: c.textSecondary),
        ),
        if (onRetry != null) ...[
          const SizedBox(height: MotifSpacing.lg),
          FilledButton.icon(
            key: const ValueKey('codex-retry'),
            onPressed: () => unawaited(onRetry!()),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ],
    );
  }
}
