import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueListenable,
        ValueNotifier,
        defaultTargetPlatform,
        kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../log/log.dart';
import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../platform/desktop_window.dart';
import '../../platform/apple_input_document.dart';
import '../../platform/window_title.dart';
import '../../state/app/app_state.dart';
import '../../state/app/motif_scope.dart';
import '../../state/workspace/remote_port/remote_port_controller.dart';
import '../../state/workspace/session_attachment.dart';
import '../../state/workspace/terminal/sticky_modifiers.dart';
import '../../state/workspace/terminal/terminal_controller.dart';
import '../../state/workspace/view/view_controller.dart';
import '../../state/workspace/workspace_api.dart';
import '../../state/workspace/connection/workspace_connection_view_model.dart';
import '../../state/workspace/workspace_view_model.dart';
import '../../terminal/native_terminal.dart';
import '../../terminal/terminal_focus_policy.dart';
import '../../terminal/terminal_error_view.dart';
import '../../terminal/terminal_input.dart';
import '../../terminal/terminal_key.dart';
import '../../terminal/terminal_palette.dart';
import '../../terminal/terminal_session.dart';
import '../theme/motif_theme.dart';
import '../widgets/observation_select.dart';
import '../widgets/quick_command_row.dart';
import '../widgets/top_toast.dart';
import 'change_directory_panel.dart';
import 'file_tree_panel.dart';
import 'git_diff_panel.dart';
import 'preview_pane.dart';
import 'quick_command_editor.dart';
import 'remote_port_mapping_sheet.dart';
import 'terminal_settings_sheet.dart';

part 'session/session_helpers.dart';
part 'session/session_input_actions.dart';
part 'session/session_terminal_actions.dart';
part 'session/session_menu_actions.dart';
part 'session/session_layout_helpers.dart';
part 'session/session_animated_layout.dart';
part 'session/session_sidebar.dart';
part 'session/session_connected_sessions.dart';
part 'session/session_tabs_and_panes.dart';
part 'session/session_bottom_bar.dart';

/// Whether to use the full libghostty-backed renderer (matches the iOS app).
/// Defaults to **on** for every native platform where the libghostty asset is
/// bundled (macOS/iOS/Android), and **off** on web. If disabled on native, the
/// app shows an explicit terminal error instead of falling back to a reduced
/// terminal surface.
final bool kUseNativeTerminal =
    !kIsWeb &&
    const bool.fromEnvironment('MOTIF_NATIVE_TERMINAL', defaultValue: true);

/// Route name used for session screens so notification taps can avoid
/// stacking a duplicate of the already-visible session.
String sessionRouteName(String serverId, String session) =>
    'session/$serverId/$session';

typedef _WorkspaceKey = ({String serverId, String session});

/// The main terminal interface: tab bar of views + active pane + input bar.
/// Mirrors SessionView. PTY panes use the libghostty-backed renderer.
class SessionScreen extends StatefulWidget {
  final String serverId;
  final String session;
  final String? initialViewId;
  const SessionScreen({
    super.key,
    required this.serverId,
    required this.session,
    this.initialViewId,
  });

  @override
  State<SessionScreen> createState() => _SessionScreenHostState();
}

/// Desktop workspace host. Every visited server/session pane stays mounted in
/// this route, so its Ghostty worker, grid, scrollback and selection survive a
/// sidebar switch. Mobile renders a single pane and keeps route navigation.
class _SessionScreenHostState extends State<SessionScreen> {
  late _WorkspaceKey _active = (
    serverId: widget.serverId,
    session: widget.session,
  );
  final List<_WorkspaceKey> _mounted = [];

  @override
  void initState() {
    super.initState();
    _mounted.add(_active);
  }

  @override
  void didUpdateWidget(covariant SessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = (serverId: widget.serverId, session: widget.session);
    if (next == _active) return;
    _selectWorkspace(next.serverId, next.session);
  }

  void _selectWorkspace(String serverId, String session) {
    final next = (serverId: serverId, session: session);
    if (next == _active) return;
    final app = ObservationScope.of<AppState>(context);
    app.workspaceForSession(serverId, session);
    setState(() {
      // Refresh recency when revisiting a pane, then evict the oldest mounted
      // pane in lockstep with AppState's bounded warm-workspace cache.
      _mounted.remove(next);
      _mounted.add(next);
      while (_mounted.length > app.maxRetainedWorkspaces) {
        _mounted.removeAt(0);
      }
      _active = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = readObservationScope<AppState>(context);
    final keepWarm = app.keepSessionWarmOnSwitchAway;
    if (!keepWarm) {
      return _scopedPane(
        app,
        serverId: widget.serverId,
        session: widget.session,
        initialViewId: widget.initialViewId,
      );
    }
    return Stack(
      children: [
        for (final workspace in _mounted)
          Positioned.fill(
            key: ValueKey(
              'workspace-${workspace.serverId}/${workspace.session}',
            ),
            child: Offstage(
              offstage: workspace != _active,
              child: TickerMode(
                enabled: workspace == _active,
                child: _scopedPane(
                  app,
                  serverId: workspace.serverId,
                  session: workspace.session,
                  initialViewId:
                      workspace.serverId == widget.serverId &&
                          workspace.session == widget.session
                      ? widget.initialViewId
                      : null,
                  workspaceActive: workspace == _active,
                  onWorkspaceSelected: _selectWorkspace,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _scopedPane(
    AppState app, {
    required String serverId,
    required String session,
    String? initialViewId,
    bool workspaceActive = true,
    void Function(String serverId, String session)? onWorkspaceSelected,
  }) {
    final capabilities = app.workspaceCapabilities(serverId, session);
    return WorkspaceScope(
      viewModel: capabilities.viewModel,
      attachment: capabilities.attachment,
      terminal: capabilities.terminal,
      views: capabilities.views,
      workspace: capabilities.workspace,
      remotePorts: capabilities.remotePorts,
      child: _SessionPane(
        serverId: serverId,
        session: session,
        initialViewId: initialViewId,
        workspaceActive: workspaceActive,
        onWorkspaceSelected: onWorkspaceSelected,
      ),
    );
  }
}

class _SessionPane extends StatefulWidget {
  final String serverId;
  final String session;
  final String? initialViewId;
  final bool workspaceActive;
  final void Function(String serverId, String session)? onWorkspaceSelected;

  const _SessionPane({
    required this.serverId,
    required this.session,
    this.initialViewId,
    this.workspaceActive = true,
    this.onWorkspaceSelected,
  });

  @override
  State<_SessionPane> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<_SessionPane>
    with WidgetsBindingObserver {
  static const double _sidebarBreakpoint = 768;
  static const double _sidebarMinWidth = 96;
  static const double _sidebarMaxWidthFraction = 0.6;
  static const double _mainMinWidth = 360;

  final StickyModifiers _modifiers = StickyModifiers();
  final Set<String> _mountedViewIds = <String>{};
  final Set<String> _appleInputDocumentIds = <String>{};
  final Map<String, _TabInputState> _tabInputs = <String, _TabInputState>{};
  late final WorkspaceViewModel _workspaceState;
  late final SessionAttachment _attachment;
  late final TerminalController _terminalController;
  late final ViewController _viewController;
  late final WorkspaceApi _workspaceApi;
  late final RemotePortController _remotePortController;
  late final _TabInputState _fallbackInput;
  late final ObservationSubscription<WorkspaceConnectionStatus> _connectionSub;
  final ValueNotifier<double> _keyboardInset = ValueNotifier(0);
  final ValueNotifier<double> _bottomBarContentHeight = ValueNotifier(
    _bottomBarCollapsedContentHeight,
  );
  DateTime? _lastKeyboardInsetLogAt;
  int _terminalFocusSerial = 0;
  bool _keyboardInsetSyncScheduled = false;
  bool _paneMountReady = false;
  bool _usesSidebarLayout = false;
  bool _shortcutRegistered = false;
  bool _switchingSession = false;
  bool _attachingSession = false;
  bool _recording = false;
  bool _micStarting = false;
  Future<void>? _autoCreatePtyFuture;
  String? _lastAppleInputDocumentId;
  String _asrBase = '';
  String _lastAsrText = ''; // last value ASR wrote to the input bar
  String? _asrInputViewId;
  bool _ignoreFinal = false; // set when the user bailed out of ASR by typing
  bool _initialViewApplied = false;

  @override
  void initState() {
    super.initState();
    _workspaceState = readObservationScope<WorkspaceViewModel>(context);
    _attachment = readObservationScope<SessionAttachment>(context);
    _terminalController = readObservationScope<TerminalController>(context);
    _viewController = readObservationScope<ViewController>(context);
    _workspaceApi = readObservationScope<WorkspaceApi>(context);
    _remotePortController = readObservationScope<RemotePortController>(context);
    _fallbackInput = _createInputState('fallback');
    _connectionSub = observe(
      () => _attachment.connection.status,
      onChange: (_) {
        unawaited(_activateInitialView());
        unawaited(_ensurePtyOnOpen());
      },
      scheduler: ObservationSchedulers.immediate,
    );
    WidgetsBinding.instance.addObserver(this);
    _scheduleKeyboardInsetSync();
    if (widget.workspaceActive) {
      _registerShortcutHandler();
      _syncWindowTitle();
    }
    // Keep the screen awake while a terminal session is on screen — a PTY can
    // sit idle for minutes waiting on output and the user shouldn't have to
    // tap to keep watching it. Mobile only; desktops manage their own display
    // sleep and shouldn't be pinned awake. Released in dispose().
    if (_wakelockApplies) WakelockPlus.enable().ignore();
    _attachIfNeeded();
  }

  /// Attach the fixed workspace if it isn't already attached. Callers navigate
  /// here immediately and the attach round trips
  /// (RPC POST + /events WebSocket) happen behind a connecting overlay instead
  /// of blocking the page transition.
  void _attachIfNeeded() {
    final attachment = _attachment;
    // While the transport is down the reconnect flow owns reattaching;
    // attaching here would just throw "not connected".
    if (!attachment.isLive) return;
    final state = attachment.connection.status;
    if (state is ConnAttached && state.session == widget.session) {
      // Already attached — this is a switch-back to a session kept warm in the
      // background. Reclaim the foreground so it reactivates its view and
      // re-advertises the terminal palette.
      attachment.setForeground(true);
      unawaited(_activateInitialView());
      // Entering a session with no terminal (e.g. all were closed) should still
      // land on a usable pane.
      unawaited(_ensurePtyOnOpen());
      return;
    }
    _attachingSession = true;
    unawaited(_attachToSession(attachment));
  }

  Future<void> _attachToSession(SessionAttachment attachment) async {
    final sw = Stopwatch()..start();
    try {
      await attachment.attach();
      Log.i(
        'open attach session=${widget.session} took=${sw.elapsedMilliseconds}ms',
        name: 'motif.ui',
      );
      await _activateInitialView();
      // A freshly-attached session with no PTYs (brand-new, or every terminal
      // closed) would open an empty pane — auto-create one. _newPty handles its
      // own errors, so it won't trip the attach catch/pop below.
      await _ensurePtyOnOpen();
    } catch (e) {
      Log.w(
        'open attach failed session=${widget.session}',
        name: 'motif.ui',
        error: e,
      );
      if (mounted) {
        showMotifToast(context, 'Attach failed: $e');
        Navigator.of(context).pop();
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _attachingSession = false);
      } else {
        _attachingSession = false;
      }
    }
  }

  Future<void> _activateInitialView() async {
    if (_initialViewApplied) return;
    final viewId = widget.initialViewId;
    if (viewId == null || viewId.isEmpty) {
      _initialViewApplied = true;
      return;
    }
    if (!_workspaceState.views.items.any((view) => view.id == viewId)) return;
    _initialViewApplied = true;
    try {
      await _viewController.activate(viewId);
    } catch (error, stackTrace) {
      Log.w(
        'notification tab activation failed view=$viewId',
        name: 'motif.ui',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mountPaneImmediately();
  }

  @override
  void didUpdateWidget(covariant _SessionPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceActive != widget.workspaceActive) {
      if (widget.workspaceActive) {
        _registerShortcutHandler();
        _syncWindowTitle();
        unawaited(_ensurePtyOnOpen());
      } else {
        _unregisterShortcutHandler();
      }
    } else if (widget.workspaceActive && oldWidget.session != widget.session) {
      _syncWindowTitle();
    }
  }

  void _registerShortcutHandler() {
    if (_shortcutRegistered) return;
    HardwareKeyboard.instance.addHandler(_handleShortcut);
    _shortcutRegistered = true;
  }

  void _unregisterShortcutHandler() {
    if (!_shortcutRegistered) return;
    HardwareKeyboard.instance.removeHandler(_handleShortcut);
    _shortcutRegistered = false;
  }

  @override
  void dispose() {
    _connectionSub.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _keyboardInset.dispose();
    _bottomBarContentHeight.dispose();
    _unregisterShortcutHandler();
    for (final id in _appleInputDocumentIds) {
      unawaited(AppleInputDocument.dispose(id).catchError((_) {}));
    }
    _appleInputDocumentIds.clear();
    _disposeInputState(_fallbackInput);
    for (final input in _tabInputs.values) {
      _disposeInputState(input);
    }
    _tabInputs.clear();
    if (_wakelockApplies) WakelockPlus.disable().ignore();
    super.dispose();
  }

  /// Ensure the visible terminal page never settles on an attached workspace
  /// with no PTY. Workspace connections attach asynchronously, so checking
  /// only from [initState] misses the common cold-open path.
  Future<void> _ensurePtyOnOpen() {
    final existing = _autoCreatePtyFuture;
    if (existing != null) return existing;
    final state = _attachment.connection.status;
    if (!mounted ||
        !widget.workspaceActive ||
        !_attachment.isLive ||
        state is! ConnAttached ||
        state.session != widget.session ||
        _terminalController.viewModel.ptys.isNotEmpty) {
      return Future<void>.value();
    }

    late final Future<void> creation;
    creation = _newPty().whenComplete(() {
      if (identical(_autoCreatePtyFuture, creation)) {
        _autoCreatePtyFuture = null;
      }
    });
    _autoCreatePtyFuture = creation;
    return creation;
  }

  @override
  void didChangeMetrics() {
    _scheduleKeyboardInsetSync();
  }

  /// Keep-screen-awake only makes sense on phones/tablets; desktops and web
  /// manage their own display sleep.
  static bool get _wakelockApplies =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  void _mountPaneImmediately() {
    if (_paneMountReady) return;
    _paneMountReady = true;
  }

  @override
  Widget build(BuildContext context) => ObservationSelect<Object?>(
    selector: () => null,
    builder: (context, _, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final media = MediaQuery.of(context);
    if ((media.viewInsets.bottom - _keyboardInset.value).abs() >= 0.5) {
      _scheduleKeyboardInsetSync();
    }
    final app = ObservationScope.of<AppState>(context);
    final c = context.motif;
    final fontSize = app.terminalSettings.settings.fontSize;
    final workspaceConnection = _workspaceState.connection;
    final overlayFromWorkspace = switch (workspaceConnection.phase) {
      WorkspaceConnectionPhase.connecting ||
      WorkspaceConnectionPhase.reconnecting => 'Connecting...',
      WorkspaceConnectionPhase.attaching => 'Attaching...',
      WorkspaceConnectionPhase.suspended =>
        workspaceConnection.blocker?.message ??
            workspaceConnection.message ??
            'Connection suspended',
      WorkspaceConnectionPhase.failed =>
        workspaceConnection.message ?? 'Connection failed',
      _ => null,
    };
    final terminalPalette = terminalPaletteForBrightness(
      Theme.of(context).brightness,
    );
    final sidebar = app.sessionSidebar;
    final sidebarState = (
      showSessions: sidebar.showSessions,
      showFileTree: sidebar.showFileTree,
      showGitDiff: sidebar.showGitDiff,
      showBottomBar: sidebar.showBottomBar,
      hasVisiblePanel: sidebar.hasVisiblePanel,
      width: sidebar.width,
      splitFraction: sidebar.splitFraction,
      firstSplitFraction: sidebar.firstSplitFraction,
      secondSplitFraction: sidebar.secondSplitFraction,
    );
    final overlayMessage =
        overlayFromWorkspace ?? (_attachingSession ? 'Connecting...' : null);
    return LayoutBuilder(
      builder: (context, constraints) {
        final usesSidebar = constraints.maxWidth >= _sidebarBreakpoint;
        _usesSidebarLayout = usesSidebar;
        final showBottomBar = !usesSidebar || sidebarState.showBottomBar;
        final showSidebar = usesSidebar && sidebarState.hasVisiblePanel;
        final sidebarMaxWidth = math.max(
          _sidebarMinWidth,
          math.min(
            constraints.maxWidth * _sidebarMaxWidthFraction,
            constraints.maxWidth - _mainMinWidth,
          ),
        );
        final sidebarWidth = sidebarState.width
            .clamp(_sidebarMinWidth, sidebarMaxWidth)
            .toDouble();
        return Title(
          title: widget.session,
          color: c.accent,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              title: usesSidebar
                  ? ObservationSelect(
                      selector: () => _tabBarSelectKey(_workspaceState),
                      builder: (context, _, _) => _TabBar(
                        workspaceState: _workspaceState,
                        terminal: _terminalController,
                        views: _viewController,
                        onNewPty: _newPty,
                        inTitleBar: true,
                      ),
                    )
                  : Text(widget.session),
              titleSpacing: usesSidebar ? 0 : null,
              toolbarHeight: usesSidebar ? 52 : null,
              leadingWidth: usesSidebar ? 104 : null,
              leading: usesSidebar
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const ValueKey('close-session-button'),
                          icon: const Icon(Icons.close),
                          tooltip:
                              'Close all sessions (${_primaryShortcutLabel('W', shift: true)})',
                          onPressed: _closeSession,
                        ),
                        IconButton(
                          key: const ValueKey('sessions-sidebar-toggle'),
                          icon: sidebarState.showSessions
                              ? const Icon(Icons.list_alt)
                              : const Icon(Icons.list_alt_outlined),
                          tooltip:
                              'Sessions (${_primaryShortcutLabel('L', shift: true)})',
                          style: _sidebarButtonStyle(
                            context,
                            c,
                            sidebarState.showSessions,
                          ),
                          onPressed: () => _toggleSessionsPanel(app),
                        ),
                      ],
                    )
                  : Center(
                      child: SizedBox(
                        width: MotifControlSize.md,
                        height: MotifControlSize.md,
                        child: Builder(
                          builder: (buttonContext) => IconButton(
                            key: const ValueKey('session-menu-button'),
                            icon: const Icon(Icons.menu),
                            tooltip: 'Session menu',
                            onPressed: () =>
                                _showSessionMenu(app, buttonContext),
                          ),
                        ),
                      ),
                    ),
              actions: [
                IconButton(
                  key: const ValueKey('file-tree-sidebar-toggle'),
                  icon: sidebarState.showFileTree
                      ? const Icon(Icons.folder)
                      : const Icon(Icons.folder_outlined),
                  tooltip: 'Files (${_primaryShortcutLabel('E', shift: true)})',
                  style: _sidebarButtonStyle(
                    context,
                    c,
                    usesSidebar && sidebarState.showFileTree,
                  ),
                  onPressed: _toggleFileTree,
                ),
                IconButton(
                  key: const ValueKey('git-diff-sidebar-toggle'),
                  icon: sidebarState.showGitDiff
                      ? const Icon(Icons.difference)
                      : const Icon(Icons.difference_outlined),
                  tooltip:
                      'Git diff (${_primaryShortcutLabel('G', shift: true)})',
                  style: _sidebarButtonStyle(
                    context,
                    c,
                    usesSidebar && sidebarState.showGitDiff,
                  ),
                  onPressed: _toggleGitDiff,
                ),
                if (usesSidebar)
                  IconButton(
                    key: const ValueKey('bottom-bar-toggle'),
                    icon: sidebarState.showBottomBar
                        ? const Icon(Icons.keyboard_alt)
                        : const Icon(Icons.keyboard_alt_outlined),
                    tooltip: 'Bottom bar',
                    style: _sidebarButtonStyle(
                      context,
                      c,
                      sidebarState.showBottomBar,
                    ),
                    onPressed: () {
                      setState(() {
                        sidebar.showBottomBar = !sidebarState.showBottomBar;
                      });
                    },
                  ),
                ObservationSelect(
                  selector: () => _workspaceState.connection.isAttached,
                  builder: (context, attached, _) => IconButton(
                    key: const ValueKey('open-remote-port-button'),
                    icon: const Icon(Icons.open_in_browser_outlined),
                    tooltip: 'Remote ports',
                    onPressed: attached
                        ? () => _showRemotePortMappings(_remotePortController)
                        : null,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Terminal settings',
                  onPressed: () => showTerminalSettingsSheet(context),
                ),
              ],
            ),
            body: _AnimatedSidebarLayout(
              visible: showSidebar,
              width: sidebarWidth,
              sidebar: ObservationSelect(
                selector: _workspaceApi.activeCwd,
                builder: (context, cwd, _) => _SessionSidebar(
                  app: app,
                  showSessions: sidebarState.showSessions,
                  showFileTree: sidebarState.showFileTree,
                  showDiff: sidebarState.showGitDiff,
                  currentServerId: widget.serverId,
                  currentSession: widget.session,
                  root: cwd ?? '~',
                  cwd: cwd,
                  workspace: _workspaceApi,
                  onSessionSelected: (serverId, session) =>
                      _switchSession(app, serverId, session),
                  onOpenPreview: _openPreview,
                  onOpenDiff: _openDiff,
                  splitFraction: sidebarState.splitFraction,
                  onSplitChanged: (fraction) {
                    setState(() => sidebar.splitFraction = fraction);
                  },
                  firstSplitFraction: sidebarState.firstSplitFraction,
                  onFirstSplitChanged: (fraction) {
                    setState(() => sidebar.firstSplitFraction = fraction);
                  },
                  secondSplitFraction: sidebarState.secondSplitFraction,
                  onSecondSplitChanged: (fraction) {
                    setState(() => sidebar.secondSplitFraction = fraction);
                  },
                ),
              ),
              resizeHandle: _SidebarResizeHandle(
                key: const ValueKey('sidebar-horizontal-resize-handle'),
                axis: Axis.horizontal,
                onDragDelta: (delta) {
                  setState(() {
                    sidebar.width = (sidebar.width + delta)
                        .clamp(_sidebarMinWidth, sidebarMaxWidth)
                        .toDouble();
                  });
                },
              ),
              mainContent: Stack(
                children: [
                  Column(
                    children: [
                      if (!usesSidebar)
                        ObservationSelect(
                          selector: () => _tabBarSelectKey(_workspaceState),
                          builder: (context, _, _) => _TabBar(
                            workspaceState: _workspaceState,
                            terminal: _terminalController,
                            views: _viewController,
                            onNewPty: _newPty,
                          ),
                        ),
                      Expanded(
                        child: ClipRect(
                          child: _BottomBarLiftedPane(
                            enabled: showBottomBar,
                            contentHeight: _bottomBarContentHeight,
                            child: ObservationSelect(
                              selector: () => _paneSelectKey(
                                _workspaceState,
                                _workspaceApi,
                              ),
                              builder: (context, _, _) {
                                final activeView = _switchingSession
                                    ? null
                                    : _workspaceState.views.active;
                                _reconcileTabInputs(
                                  _workspaceState.views.items,
                                  activeView,
                                );
                                _syncAppleInputDocument(activeView?.id);
                                final mountedViews = _paneMountReady
                                    ? _mountedViews(activeView)
                                    : const <ViewInfo>[];
                                return _PaneStack(
                                  activeView: activeView,
                                  attaching: _attachingSession,
                                  mountPanes: _paneMountReady,
                                  workspaceActive: widget.workspaceActive,
                                  mountedViews: mountedViews,
                                  terminal: _terminalController,
                                  workspace: _workspaceApi,
                                  fontSize: fontSize,
                                  palette: terminalPalette,
                                  focusSerial: _terminalFocusSerial,
                                  keyboardInset: _keyboardInset,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      if (showBottomBar) const _BottomBarPlaceholder(),
                    ],
                  ),
                  if (showBottomBar)
                    Positioned.fill(
                      child: _KeyboardAnchoredBottomBar(
                        keyboardInset: _keyboardInset,
                        child: ObservationSelect(
                          selector: () => _bottomBarSelectKey(_workspaceState),
                          builder: (context, snap, _) {
                            final commandStore = ObservationScope.of<AppState>(
                              context,
                            ).commands;
                            final runningProgram = snap.runningProgram;
                            final inputState = _inputStateForView(
                              snap.activeViewId,
                            );
                            return ObservationSelect(
                              selector: () =>
                                  commandStore.resolved(runningProgram),
                              builder: (context, commands, _) {
                                return _MeasureSize(
                                  onChange: _setBottomBarContentSize,
                                  child: ColoredBox(
                                    color: c.background,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        QuickCommandRow(
                                          commands: commands,
                                          modifiers: _modifiers,
                                          onSendBytes: (b) => _sendBytes(b),
                                          onSendKey: (input) async {
                                            await _dispatchTerminalInput(input);
                                          },
                                          onPaste: (bytes) async {
                                            await _sendPasteBytes(bytes);
                                          },
                                          onSendCommandBytes: (b) =>
                                              _sendCommandBytes(b),
                                          onInsertText: _insertText,
                                          onChangeDirectory:
                                              _openChangeDirectory,
                                          onEdit: () =>
                                              Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      QuickCommandEditor(
                                                        setId: commandStore
                                                            .effectiveSetId(
                                                              runningProgram,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                        ),
                                        _InputBar(
                                          key: ValueKey(
                                            'bottom-input-${snap.activeViewId ?? 'fallback'}',
                                          ),
                                          controller: inputState.controller,
                                          focusNode: inputState.focusNode,
                                          groupId: inputState.groupId,
                                          onSend: _send,
                                          recording: _recording,
                                          micStarting: _micStarting,
                                          onMic: _toggleMic,
                                          onAttach: _attachPhoto,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  if (overlayMessage != null)
                    Positioned(
                      top: MotifSpacing.sm,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: _ReconnectBanner(message: overlayMessage),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Small pill shown over the terminal while the connection is being
/// re-established. Input is blocked while the workspace is unavailable.
class _ReconnectBanner extends StatelessWidget {
  final String message;

  const _ReconnectBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.surfaceElevated,
        borderRadius: BorderRadius.circular(MotifRadius.md),
        border: Border.all(color: c.border),
        boxShadow: MotifElevation.overlay(c.shadow),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
          ),
          const SizedBox(width: MotifSpacing.sm),
          Text(
            message,
            style: MotifType.callout.copyWith(color: c.textPrimary),
          ),
        ],
      ),
    );
  }
}
