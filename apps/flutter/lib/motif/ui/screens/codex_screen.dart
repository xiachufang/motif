import 'dart:async';

import 'package:flutter/material.dart';

import '../../codex/codex_connection_controller.dart';
import '../../codex/codex_feature_controller.dart';
import '../../codex/codex_resource_intent.dart';
import '../../codex/codex_service_state.dart';
import '../../codex/codex_state.dart';
import '../../codex/codex_thread_catalog.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../../platform/window_title.dart';
import '../theme/motif_theme.dart';
import '../widgets/observation_select.dart';
import '../widgets/top_toast.dart';
import 'codex_thread_sidebar.dart';
import 'codex_thread_workspace.dart';
import 'side_chat_screen.dart';

class CodexScreen extends StatefulWidget {
  const CodexScreen({
    required this.controller,
    required this.onWorkspaceRequested,
    super.key,
  });

  final CodexFeatureController controller;
  final Future<void> Function(CodexWorkspaceRequest request)
  onWorkspaceRequested;

  @override
  State<CodexScreen> createState() => _CodexScreenState();
}

class _CodexScreenState extends State<CodexScreen> {
  static const double _mobileBreakpoint = 768;
  static const double _sidebarMinWidth = 260;
  static const double _resizeHandleWidth = 8;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _workspaceOpening = false;
  bool _initializedSidebarVisibility = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(widget.controller.start());
    unawaited(MotifWindowTitle.set('Codex — Motif').catchError((_) {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initializedSidebarVisibility) return;
    widget.controller.preferences.desktopSidebarVisible = true;
    _initializedSidebarVisibility = true;
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final codex = widget.controller.preferences;
    final serviceState = widget.controller.service;
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
            drawerEnableOpenDragGesture: mobile && serviceState != null,
            drawerEdgeDragWidth: 48,
            appBar: AppBar(
              leadingWidth: canPop ? 96 : null,
              leading: canPop
                  ? Row(children: [const CloseButton(), sidebarToggle])
                  : sidebarToggle,
              title: _CodexAppBarTitle(thread: serviceState?.selectedThread),
              actions: [
                IconButton(
                  key: const ValueKey('open-side-chat'),
                  tooltip: 'Open Side Chat',
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  onPressed:
                      !widget.controller.sideChatOpening &&
                          serviceState?.selectedThread != null
                      ? () => unawaited(_openSideChat(serviceState!))
                      : null,
                ),
                IconButton(
                  key: const ValueKey('codex-open-thread-workspace'),
                  tooltip: 'Open thread workspace',
                  icon: const Icon(Icons.terminal_rounded),
                  onPressed:
                      !_workspaceOpening && serviceState?.selectedThread != null
                      ? () => unawaited(
                          _requestWorkspace(serviceState!.selectedThread!),
                        )
                      : null,
                ),
                PopupMenuButton<CodexServiceAction>(
                  key: const ValueKey('codex-service-menu'),
                  tooltip: 'Codex service',
                  enabled: !widget.controller.operationInFlight,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: CodexServiceAction.restart,
                      child: Text('Restart Codex'),
                    ),
                    PopupMenuItem(
                      value: CodexServiceAction.stop,
                      child: Text('Stop Codex'),
                    ),
                  ],
                  onSelected: (action) => unawaited(_controlService(action)),
                ),
              ],
            ),
            drawer: mobile && serviceState != null
                ? Drawer(
                    width: (constraints.maxWidth * 0.88)
                        .clamp(_sidebarMinWidth, 360)
                        .toDouble(),
                    child: _sidebar(
                      serviceState,
                      chrome.mode,
                      codex,
                      mobile: true,
                    ),
                  )
                : null,
            body: widget.controller.setupError != null
                ? _MainSurface(
                    child: _Failure(error: widget.controller.setupError!),
                  )
                : serviceState == null
                ? const _MainSurface(child: CircularProgressIndicator())
                : mobile
                ? _mainContent(
                    serviceState,
                    onOpenSidebar: () =>
                        _scaffoldKey.currentState?.openDrawer(),
                  )
                : _desktopBody(constraints, serviceState, codex, chrome),
          );
        },
      ),
    );
  }

  Widget _desktopBody(
    BoxConstraints constraints,
    CodexServiceState serviceState,
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
            child: _sidebar(serviceState, chrome.mode, codex, mobile: false),
          ),
          _SidebarResizeHandle(
            onDragDelta: (delta) {
              codex.sidebarWidth = (width + delta)
                  .clamp(_sidebarMinWidth, maxWidth)
                  .toDouble();
            },
          ),
        ],
        Expanded(child: _mainContent(serviceState)),
      ],
    );
  }

  Widget _sidebar(
    CodexServiceState serviceState,
    CodexSidebarMode mode,
    CodexState codex, {
    required bool mobile,
  }) => CodexThreadSidebar(
    serviceState: serviceState,
    codexState: codex,
    mode: mode,
    onModeChanged: (value) => codex.sidebarMode = value,
    onThreadSelected: (threadId) {
      if (mobile && _scaffoldKey.currentState?.isDrawerOpen == true) {
        Navigator.of(context).pop();
      }
      unawaited(serviceState.readThread(threadId));
    },
  );

  Widget _mainContent(CodexServiceState state, {VoidCallback? onOpenSidebar}) {
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
                child: _Connected(
                  serviceState: state,
                  onOpenSidebar: onOpenSidebar,
                ),
              )
            : CodexThreadWorkspace(
                state: state,
                onOpenResource: (resource) => _requestWorkspace(
                  state.selectedThread!,
                  resource: resource,
                ),
              ),
      CodexConnectionPhase.failed => _MainSurface(
        child: _Failure(
          error: connection.error ?? 'Connection failed',
          onRetry: state.retryConnection,
        ),
      ),
    };
  }

  Future<void> _requestWorkspace(
    CodexThread thread, {
    CodexResourceIntent? resource,
  }) async {
    if (_workspaceOpening) return;
    final cwd = thread.cwd.value.trim();
    if (cwd.isEmpty) {
      showMotifToast(context, 'This thread does not have a working directory');
      return;
    }
    setState(() => _workspaceOpening = true);
    try {
      await widget.onWorkspaceRequested(
        CodexWorkspaceRequest(
          threadId: thread.id,
          cwd: cwd,
          title: codexThreadTitle(thread),
          resource: resource,
        ),
      );
      if (mounted) {
        unawaited(MotifWindowTitle.set('Codex — Motif').catchError((_) {}));
      }
    } catch (error) {
      if (mounted) showMotifToast(context, 'Open workspace failed: $error');
    } finally {
      if (mounted) setState(() => _workspaceOpening = false);
    }
  }

  Future<void> _openSideChat(CodexServiceState state) async {
    final thread = state.selectedThread;
    if (thread == null || widget.controller.sideChatOpening) return;
    final collection = widget.controller.openSideChats();
    if (collection == null) return;
    widget.controller.setSideChatOpening(true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: 'side-chat/${widget.controller.serverId}/${thread.id}',
          ),
          builder: (_) => SideChatScreen(
            collection: collection,
            onOpenResource: (resource) async {
              await _requestWorkspace(thread, resource: resource);
              if (mounted) {
                unawaited(
                  MotifWindowTitle.set('Side Chat — Motif').catchError((_) {}),
                );
              }
            },
          ),
        ),
      );
    } finally {
      if (mounted) {
        unawaited(MotifWindowTitle.set('Codex — Motif').catchError((_) {}));
      }
      widget.controller.setSideChatOpening(false);
    }
  }

  Future<void> _controlService(CodexServiceAction action) async {
    try {
      final completed = await widget.controller.runServiceAction(action);
      if (!mounted) return;
      if (completed && action == CodexServiceAction.stop) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) showMotifToast(context, 'Codex operation failed: $error');
    }
  }
}

class _CodexAppBarTitle extends StatelessWidget {
  const _CodexAppBarTitle({required this.thread});

  final CodexThread? thread;

  @override
  Widget build(BuildContext context) {
    final thread = this.thread;
    if (thread == null) return const Text('Codex');

    final c = context.motif;
    final cwd = thread.cwd.value.trim();
    return Row(
      key: const ValueKey('codex-thread-appbar-title'),
      children: [
        Icon(
          Icons.folder_outlined,
          size: MotifIconSize.sm,
          color: c.textSecondary,
        ),
        const SizedBox(width: MotifSpacing.sm),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                codexThreadTitle(thread),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MotifType.headline.copyWith(color: c.textPrimary),
              ),
              if (cwd.isNotEmpty)
                Text(
                  cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.caption.copyWith(color: c.textTertiary),
                ),
            ],
          ),
        ),
      ],
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
          width: _CodexScreenState._resizeHandleWidth,
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
  const _Connected({required this.serviceState, this.onOpenSidebar});

  final CodexServiceState serviceState;
  final VoidCallback? onOpenSidebar;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final catalogFailed = serviceState.catalogPhase == CodexCatalogPhase.failed;
    final threadCount = serviceState.catalog.allThreads.length;
    return Column(
      key: const ValueKey('codex-connected'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: c.accentContainer,
            borderRadius: BorderRadius.circular(MotifRadius.xl),
          ),
          child: Icon(Icons.auto_awesome_rounded, size: 32, color: c.accent),
        ),
        const SizedBox(height: MotifSpacing.xl),
        Text(
          'Start with a thread',
          textAlign: TextAlign.center,
          style: MotifType.display.copyWith(color: c.textPrimary),
        ),
        const SizedBox(height: MotifSpacing.sm),
        Text(
          onOpenSidebar != null
              ? threadCount == 0
                    ? 'Open Threads to start your first task in a project.'
                    : 'Open Threads to continue a recent task or start something new.'
              : threadCount == 0
              ? 'Create your first task from a project in Threads.'
              : 'Choose a recent task from Threads, or start something new.',
          textAlign: TextAlign.center,
          style: MotifType.subhead.copyWith(
            color: c.textSecondary,
            height: 1.5,
          ),
        ),
        if (onOpenSidebar != null) ...[
          const SizedBox(height: MotifSpacing.xl),
          FilledButton.icon(
            key: const ValueKey('codex-open-sidebar-cta'),
            onPressed: onOpenSidebar,
            icon: const Icon(Icons.view_sidebar_outlined),
            label: const Text('Open Threads'),
          ),
          const SizedBox(height: MotifSpacing.md),
          Text(
            'You can also swipe in from the left edge.',
            textAlign: TextAlign.center,
            style: MotifType.caption.copyWith(color: c.textTertiary),
          ),
        ],
        const SizedBox(height: MotifSpacing.xxl),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: MotifSpacing.md,
            vertical: MotifSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: catalogFailed
                ? c.warning.withValues(alpha: 0.08)
                : c.subtleFill,
            borderRadius: BorderRadius.circular(MotifRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                catalogFailed
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline_rounded,
                size: MotifIconSize.sm,
                color: catalogFailed ? c.warning : c.success,
              ),
              const SizedBox(width: MotifSpacing.sm),
              Text(
                catalogFailed
                    ? 'Threads could not be loaded'
                    : 'Codex is ready',
                style: MotifType.callout.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
        if (catalogFailed) ...[
          const SizedBox(height: MotifSpacing.md),
          OutlinedButton.icon(
            onPressed: () => unawaited(serviceState.retryCatalog()),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ],
      ],
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
