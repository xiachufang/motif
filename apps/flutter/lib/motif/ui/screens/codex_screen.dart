import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../codex/codex_connection_controller.dart';
import '../../codex/codex_feature_controller.dart';
import '../../codex/codex_navigation.dart';
import '../../codex/codex_service_state.dart';
import '../../codex/codex_state.dart';
import '../../codex/codex_thread_catalog.dart';
import '../../codex/side_chat_collection_controller.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../../models/resource_documents.dart';
import '../../platform/window_title.dart';
import '../theme/motif_theme.dart';
import '../widgets/codex_motion.dart';
import '../widgets/observation_select.dart';
import '../widgets/top_toast.dart';
import 'codex_thread_sidebar.dart';
import 'codex_thread_workspace.dart';
import 'codex_resource_screens.dart';
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
    unawaited(_startController());
    unawaited(MotifWindowTitle.set('Codex — Motif').catchError((_) {}));
  }

  Future<void> _startController() async {
    await widget.controller.start();
    if (!mounted) return;
    final collection = widget.controller.takePendingInitialSideChat();
    if (collection == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.sizeOf(context).width < _mobileBreakpoint) {
        _scaffoldKey.currentState?.openEndDrawer();
      } else {
        unawaited(_showSideChat(collection));
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initializedSidebarVisibility) return;
    widget.controller.preferences.desktopSidebarVisible = true;
    _initializedSidebarVisibility = true;
  }

  @override
  Widget build(BuildContext context) {
    final codex = widget.controller.preferences;
    return ObservationSelect<
      ({
        CodexSidebarMode mode,
        bool visible,
        double width,
        CodexServiceState? service,
        String? setupError,
        bool operationInFlight,
        bool sideChatOpening,
        CodexConnectionState? connection,
        CodexThread? selectedThread,
        String? readingThreadId,
      })
    >(
      selector: () {
        final feature = widget.controller.viewModel;
        final service = feature.service;
        final conversation = service?.viewModel;
        return (
          mode: codex.sidebarMode,
          visible: codex.desktopSidebarVisible,
          width: codex.sidebarWidth,
          service: service,
          setupError: feature.setupError,
          operationInFlight: feature.operationInFlight,
          sideChatOpening: feature.sideChatOpening,
          connection: conversation?.connectionState,
          selectedThread: conversation?.selectedThread,
          readingThreadId: conversation?.readingThreadId,
        );
      },
      builder: (context, chrome, _) => LayoutBuilder(
        builder: (context, constraints) {
          final serviceState = chrome.service;
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
            endDrawerEnableOpenDragGesture:
                mobile &&
                serviceState != null &&
                chrome.selectedThread != null &&
                !chrome.sideChatOpening,
            drawerEdgeDragWidth: 48,
            onEndDrawerChanged: (open) {
              widget.controller.setSideChatOpening(open);
              unawaited(
                MotifWindowTitle.set(
                  open ? 'Side Chat — Motif' : 'Codex — Motif',
                ).catchError((_) {}),
              );
            },
            appBar: AppBar(
              leadingWidth: canPop ? 96 : null,
              leading: canPop
                  ? Row(children: [const CloseButton(), sidebarToggle])
                  : sidebarToggle,
              title: CodexMotionSwitcher(
                offset: const Offset(0, 0.12),
                child: _CodexAppBarTitle(
                  key: ValueKey(
                    'codex-appbar-${chrome.selectedThread?.id ?? 'empty'}',
                  ),
                  thread: chrome.selectedThread,
                ),
              ),
              actions: [
                IconButton(
                  key: const ValueKey('open-side-chat'),
                  tooltip: 'Open Side Chat',
                  icon: CodexMotionSwitcher(
                    offset: Offset.zero,
                    child: chrome.sideChatOpening
                        ? const SizedBox.square(
                            key: ValueKey('side-chat-opening'),
                            dimension: MotifIconSize.md,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.chat_bubble_outline_rounded,
                            key: ValueKey('side-chat-icon'),
                          ),
                  ),
                  onPressed:
                      !chrome.sideChatOpening && chrome.selectedThread != null
                      ? () => unawaited(
                          _openSideChat(serviceState!, drawer: mobile),
                        )
                      : null,
                ),
                IconButton(
                  key: const ValueKey('codex-open-thread-workspace'),
                  tooltip: 'Open thread workspace',
                  icon: CodexMotionSwitcher(
                    offset: Offset.zero,
                    child: _workspaceOpening
                        ? const SizedBox.square(
                            key: ValueKey('codex-workspace-opening'),
                            dimension: MotifIconSize.md,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.terminal_rounded,
                            key: ValueKey('codex-workspace-icon'),
                          ),
                  ),
                  onPressed: !_workspaceOpening && chrome.selectedThread != null
                      ? () => unawaited(
                          _requestWorkspace(serviceState!.selectedThread!),
                        )
                      : null,
                ),
                PopupMenuButton<CodexServiceAction>(
                  key: const ValueKey('codex-service-menu'),
                  tooltip: 'Codex service',
                  enabled: !chrome.operationInFlight,
                  icon: CodexMotionSwitcher(
                    offset: Offset.zero,
                    child: chrome.operationInFlight
                        ? const SizedBox.square(
                            key: ValueKey('codex-service-busy'),
                            dimension: MotifIconSize.md,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.more_vert,
                            key: ValueKey('codex-service-actions'),
                          ),
                  ),
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
            endDrawer:
                mobile && serviceState != null && chrome.selectedThread != null
                ? Drawer(
                    key: const ValueKey('codex-side-chat-drawer'),
                    width: constraints.maxWidth,
                    child: _LazySideChatDrawer(
                      key: ValueKey(
                        'side-chat-drawer-${chrome.selectedThread!.id}',
                      ),
                      controller: widget.controller,
                    ),
                  )
                : null,
            body: chrome.setupError != null
                ? _MainSurface(child: _Failure(error: chrome.setupError!))
                : serviceState == null
                ? const _MainSurface(child: CircularProgressIndicator())
                : mobile
                ? _mainContent(
                    serviceState,
                    connection: chrome.connection!,
                    selectedThread: chrome.selectedThread,
                    readingThreadId: chrome.readingThreadId,
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
    ({
      CodexSidebarMode mode,
      bool visible,
      double width,
      CodexServiceState? service,
      String? setupError,
      bool operationInFlight,
      bool sideChatOpening,
      CodexConnectionState? connection,
      CodexThread? selectedThread,
      String? readingThreadId,
    })
    chrome,
  ) {
    final maxWidth = constraints.maxWidth * 0.6;
    final width = chrome.width.clamp(_sidebarMinWidth, maxWidth).toDouble();
    return CodexAnimatedSidebarLayout(
      visible: chrome.visible,
      sidebarExtent: width + _resizeHandleWidth,
      sidebar: Row(
        children: [
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
      ),
      mainContent: _mainContent(
        serviceState,
        connection: chrome.connection!,
        selectedThread: chrome.selectedThread,
        readingThreadId: chrome.readingThreadId,
      ),
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
      if (mobile) _closeMobileSidebar();
      unawaited(serviceState.readThread(threadId));
    },
    onThreadCreated: mobile ? _closeMobileSidebar : null,
  );

  void _closeMobileSidebar() {
    if (_scaffoldKey.currentState?.isDrawerOpen == true) {
      Navigator.of(context).pop();
    }
  }

  Widget _mainContent(
    CodexServiceState state, {
    required CodexConnectionState connection,
    required CodexThread? selectedThread,
    required String? readingThreadId,
    VoidCallback? onOpenSidebar,
  }) {
    final child = switch (connection.phase) {
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
        readingThreadId != null
            ? const _MainSurface(
                child: _Progress(
                  key: ValueKey('codex-thread-loading'),
                  title: 'Loading thread',
                ),
              )
            : selectedThread == null
            ? _MainSurface(
                child: _Connected(
                  serviceState: state,
                  onOpenSidebar: onOpenSidebar,
                ),
              )
            : KeyedSubtree(
                key: ValueKey('codex-thread-${selectedThread.id}'),
                child: CodexThreadWorkspace(
                  state: state.selectedConversation ?? state,
                  codexState: widget.controller.preferences,
                  onOpenFile: (path) =>
                      _openFile(state.selectedConversation ?? state, path),
                  onOpenImage: (path) => _openFile(
                    state.selectedConversation ?? state,
                    path,
                    image: true,
                  ),
                  onOpenTurnDiff: (document, {initialPath}) => _openTurnDiff(
                    state.selectedConversation ?? state,
                    document,
                    initialPath: initialPath,
                  ),
                ),
              ),
      CodexConnectionPhase.failed => _MainSurface(
        child: _Failure(
          title:
              connection.failureKind == CodexConnectionFailureKind.cliNotFound
              ? 'Codex CLI not found'
              : 'Codex connection failed',
          error: connection.error ?? 'Connection failed',
          onRetry: state.retryConnection,
        ),
      ),
    };
    final transitionKey = switch (connection.phase) {
      CodexConnectionPhase.connecting => 'connecting',
      CodexConnectionPhase.initializing => 'initializing',
      CodexConnectionPhase.failed => 'failed',
      CodexConnectionPhase.connected when readingThreadId != null =>
        'loading-$readingThreadId',
      CodexConnectionPhase.connected when selectedThread == null => 'empty',
      CodexConnectionPhase.connected => 'thread-${selectedThread!.id}',
    };
    return CodexMotionSwitcher(
      child: KeyedSubtree(key: ValueKey(transitionKey), child: child),
    );
  }

  Future<void> _requestWorkspace(CodexThread thread) async {
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

  Future<void> _openFile(
    CodexConversationState state,
    String path, {
    bool image = false,
  }) {
    final uri = Uri.tryParse(path);
    final networkImage =
        image &&
        uri != null &&
        const {'http', 'https', 'data'}.contains(uri.scheme);
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: RouteSettings(
          name: 'codex-file/${widget.controller.serverId}',
        ),
        builder: (_) => networkImage
            ? CodexNetworkImageScreen(url: path)
            : CodexFilePreviewScreen(state: state, path: path, image: image),
      ),
    );
  }

  Future<void> _openTurnDiff(
    CodexConversationState state,
    DiffDocument document, {
    String? initialPath,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: RouteSettings(
        name: 'codex-turn-diff/${widget.controller.serverId}',
      ),
      builder: (_) => CodexTurnDiffScreen(
        document: document,
        initialPath: initialPath,
        onOpenFile: (path) => _openFile(state, path),
      ),
    ),
  );

  Future<void> _openSideChat(
    CodexServiceState state, {
    bool drawer = false,
  }) async {
    final thread = state.selectedThread;
    if (thread == null || widget.controller.sideChatOpening) return;
    if (drawer) {
      _scaffoldKey.currentState?.openEndDrawer();
      return;
    }
    final collection = widget.controller.openSideChats();
    if (collection == null) return;
    await _showSideChat(collection);
  }

  Future<void> _showSideChat(SideChatCollectionController collection) async {
    widget.controller.setSideChatOpening(true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name:
                'side-chat/${widget.controller.serverId}/${collection.parentThreadId}',
          ),
          builder: (_) => SideChatScreen(
            collection: collection,
            codexState: widget.controller.preferences,
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

class _LazySideChatDrawer extends StatefulWidget {
  const _LazySideChatDrawer({required this.controller, super.key});

  final CodexFeatureController controller;

  @override
  State<_LazySideChatDrawer> createState() => _LazySideChatDrawerState();
}

class _LazySideChatDrawerState extends State<_LazySideChatDrawer> {
  SideChatCollectionController? _collection;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _collection = widget.controller.openSideChats());
    });
  }

  @override
  Widget build(BuildContext context) {
    final collection = _collection;
    if (collection == null) {
      return ColoredBox(
        color: context.motif.surface,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return SideChatScreen(
      collection: collection,
      codexState: widget.controller.preferences,
      manageWindowTitle: false,
    );
  }
}

class _CodexAppBarTitle extends StatelessWidget {
  const _CodexAppBarTitle({required this.thread, super.key});

  final CodexThread? thread;

  @override
  Widget build(BuildContext context) {
    final thread = this.thread;
    if (thread == null) return const Text('Codex');

    final c = context.motif;
    return Text(
      key: const ValueKey('codex-thread-appbar-title'),
      codexThreadTitle(thread),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: MotifType.headline.copyWith(color: c.textPrimary),
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
        if (catalogFailed) ...[
          const SizedBox(height: MotifSpacing.xxl),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: MotifSpacing.md,
              vertical: MotifSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: c.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(MotifRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: MotifIconSize.sm,
                  color: c.warning,
                ),
                const SizedBox(width: MotifSpacing.sm),
                Text(
                  'Threads could not be loaded',
                  style: MotifType.callout.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
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
  const _Failure({
    required this.error,
    this.title = 'Codex connection failed',
    this.onRetry,
  });
  final String title;
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
        Text(title, style: MotifType.title.copyWith(color: c.textPrimary)),
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
