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
import '../../models/coding_agent_hooks.dart';
import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../platform/desktop_window.dart';
import '../../platform/apple_input_document.dart';
import '../../platform/window_title.dart';
import '../../session/session_feature_runtime.dart';
import '../../state/dependency_scope.dart';
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
import '../../terminal/terminal_link.dart';
import '../../terminal/terminal_palette.dart';
import '../../terminal/terminal_session.dart';
import '../theme/motif_theme.dart';
import '../widgets/observation_select.dart';
import '../widgets/quick_command_row.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/top_toast.dart';
import 'change_directory_panel.dart';
import 'file_tree_panel.dart';
import 'git_diff_panel.dart';
import 'preview_pane.dart';
import 'remote_port_mapping_sheet.dart';
import 'screen_capture_flow.dart';

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

bool _sameViewSpec(ViewSpec left, ViewSpec right) => switch ((left, right)) {
  (PtyViewSpec(:final ptyId), PtyViewSpec(ptyId: final other)) =>
    ptyId == other,
  (PreviewViewSpec(:final path), PreviewViewSpec(path: final other)) =>
    path == other,
  (
    DiffViewSpec(:final staged, :final path),
    DiffViewSpec(staged: final otherStaged, path: final otherPath),
  ) =>
    staged == otherStaged && path == otherPath,
  (ImageViewSpec(:final path), ImageViewSpec(path: final other)) =>
    path == other,
  (OtherViewSpec(:final typeName), OtherViewSpec(typeName: final other)) =>
    typeName == other,
  _ => false,
};

ViewSpec? _viewSpecForTarget(SessionOpenTarget? target) => switch (target) {
  SessionFileTarget(:final path) => PreviewViewSpec(path),
  SessionDiffTarget(:final path, :final staged) => DiffViewSpec(
    path: path,
    staged: staged,
  ),
  SessionImageTarget(:final path) => ImageViewSpec(path),
  null => null,
};

typedef _WorkspaceKey = ({String serverId, String session});

CodingAgent? codingAgentForCommand(String? command) =>
    switch (programKey(command)) {
      'claude' => CodingAgent.claude,
      'codex' => CodingAgent.codex,
      _ => null,
    };

/// The main terminal interface: tab bar of views + active pane + input bar.
/// Mirrors SessionView. PTY panes use the libghostty-backed renderer.
class SessionScreen extends StatefulWidget {
  final String serverId;
  final String session;
  final String? initialViewId;
  final SessionOpenTarget? initialTarget;
  final bool allowSessionSwitching;
  final String? titleOverride;
  const SessionScreen({
    super.key,
    required this.serverId,
    required this.session,
    this.initialViewId,
    this.initialTarget,
    this.allowSessionSwitching = true,
    this.titleOverride,
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
    final runtime = ObservationScope.of<SessionFeatureRuntime>(context);
    runtime.retainWorkspace(serverId, session);
    setState(() {
      // Refresh recency when revisiting a pane, then evict the oldest mounted
      // pane in lockstep with the runtime's bounded warm-workspace cache.
      _mounted.remove(next);
      _mounted.add(next);
      while (_mounted.length > runtime.maxRetainedWorkspaces) {
        _mounted.removeAt(0);
      }
      _active = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final runtime = readObservationScope<SessionFeatureRuntime>(context);
    final keepWarm = runtime.keepWorkspaceWarm;
    if (!keepWarm) {
      return _scopedPane(
        runtime,
        serverId: widget.serverId,
        session: widget.session,
        initialViewId: widget.initialViewId,
        initialTarget: widget.initialTarget,
        allowSessionSwitching: widget.allowSessionSwitching,
        titleOverride: widget.titleOverride,
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
                  runtime,
                  serverId: workspace.serverId,
                  session: workspace.session,
                  initialViewId:
                      workspace.serverId == widget.serverId &&
                          workspace.session == widget.session
                      ? widget.initialViewId
                      : null,
                  initialTarget:
                      workspace.serverId == widget.serverId &&
                          workspace.session == widget.session
                      ? widget.initialTarget
                      : null,
                  allowSessionSwitching: widget.allowSessionSwitching,
                  titleOverride: widget.titleOverride,
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
    SessionFeatureRuntime runtime, {
    required String serverId,
    required String session,
    String? initialViewId,
    SessionOpenTarget? initialTarget,
    required bool allowSessionSwitching,
    String? titleOverride,
    bool workspaceActive = true,
    void Function(String serverId, String session)? onWorkspaceSelected,
  }) {
    final capabilities = runtime.workspaceCapabilities(serverId, session);
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
        initialViewSpec: _viewSpecForTarget(initialTarget),
        allowSessionSwitching: allowSessionSwitching,
        titleOverride: titleOverride,
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
  final ViewSpec? initialViewSpec;
  final bool allowSessionSwitching;
  final String? titleOverride;
  final bool workspaceActive;
  final void Function(String serverId, String session)? onWorkspaceSelected;

  const _SessionPane({
    required this.serverId,
    required this.session,
    this.initialViewId,
    this.initialViewSpec,
    required this.allowSessionSwitching,
    this.titleOverride,
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
  static const double _mobileDrawerMaxWidth = 400;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final StickyModifiers _modifiers = StickyModifiers();
  final Set<String> _mountedViewIds = <String>{};
  final Set<String> _appleInputDocumentIds = <String>{};
  final Map<String, _TabInputState> _tabInputs = <String, _TabInputState>{};
  late final WorkspaceViewModel _workspaceState;
  late final SessionFeatureRuntime _runtime;
  late final SessionAttachment _attachment;
  late final TerminalController _terminalController;
  late final ViewController _viewController;
  late final WorkspaceApi _workspaceApi;
  late final RemotePortController _remotePortController;
  late final _TabInputState _fallbackInput;
  late final ObservationSubscription<WorkspaceConnectionStatus> _connectionSub;
  late final ObservationSubscription<List<String>> _runningCommandsSub;
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
  bool _codingAgentHookCheckInFlight = false;
  bool _recording = false;
  bool _micStarting = false;
  Future<void>? _autoCreatePtyFuture;
  String? _lastAppleInputDocumentId;
  String? _fileTreeRoot;
  String? _lastWindowTitle;
  String _asrBase = '';
  String _lastAsrText = ''; // last value ASR wrote to the input bar
  String? _asrInputViewId;
  bool _ignoreFinal = false; // set when the user bailed out of ASR by typing
  bool _initialViewApplied = false;
  bool _initialViewOpening = false;
  _MobileEndDrawerPanel _mobileEndDrawerPanel = _MobileEndDrawerPanel.files;

  @override
  void initState() {
    super.initState();
    _runtime = readObservationScope<SessionFeatureRuntime>(context);
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
    _runningCommandsSub = observe(
      () => _terminalController.viewModel.runningCommand.values.toList(
        growable: false,
      ),
      onChange: (_) => _scheduleCodingAgentHookCheck(),
      scheduler: ObservationSchedulers.immediate,
    );
    WidgetsBinding.instance.addObserver(this);
    _scheduleKeyboardInsetSync();
    _scheduleCodingAgentHookCheck();
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
    if (_initialViewApplied || _initialViewOpening) return;
    final viewId = widget.initialViewId;
    final viewSpec = widget.initialViewSpec;
    if ((viewId == null || viewId.isEmpty) && viewSpec == null) {
      _initialViewApplied = true;
      return;
    }
    if (viewSpec != null && _attachment.connection.status is! ConnAttached) {
      return;
    }
    final existing = viewSpec == null
        ? _workspaceState.views.items
              .where((view) => view.id == viewId)
              .firstOrNull
        : _workspaceState.views.items
              .where((view) => _sameViewSpec(view.spec, viewSpec))
              .firstOrNull;
    if (viewSpec == null && existing == null) return;
    _initialViewOpening = true;
    try {
      if (existing != null) {
        await _viewController.activate(existing.id);
      } else {
        await _viewController.open(spec: viewSpec!, activate: true);
      }
      _initialViewApplied = true;
    } catch (error, stackTrace) {
      Log.w(
        'initial tab activation failed view=${viewId ?? viewSpec.runtimeType}',
        name: 'motif.ui',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _initialViewOpening = false;
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
        _scheduleCodingAgentHookCheck();
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
    _runningCommandsSub.dispose();
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

  void _scheduleCodingAgentHookCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkCodingAgentHookPrompt();
    });
  }

  void _checkCodingAgentHookPrompt() {
    if (_codingAgentHookCheckInFlight || !widget.workspaceActive) return;
    if (!_runtime.canCheckCodingAgentHooks(widget.serverId)) return;
    for (final command in _terminalController.viewModel.runningCommand.values) {
      final agent = codingAgentForCommand(command);
      if (agent == null ||
          _runtime.codingAgentHookPromptShown(widget.serverId, agent)) {
        continue;
      }
      unawaited(_maybePromptCodingAgentHook(agent));
      return;
    }
  }

  bool _isCodingAgentRunning(CodingAgent agent) => _terminalController
      .viewModel
      .runningCommand
      .values
      .any((command) => codingAgentForCommand(command) == agent);

  Future<void> _maybePromptCodingAgentHook(CodingAgent agent) async {
    if (_codingAgentHookCheckInFlight) return;
    _codingAgentHookCheckInFlight = true;
    var installRequested = false;
    try {
      if (!await _runtime.claimCodingAgentHookPrompt(widget.serverId, agent)) {
        return;
      }
      if (!mounted ||
          !widget.workspaceActive ||
          !_isCodingAgentRunning(agent)) {
        return;
      }

      final install = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: ValueKey('${agent.name}-hook-install-prompt'),
          title: Text('Install the ${agent.label} hook?'),
          content: Text(
            'Motif can notify you when ${agent.label} finishes or needs '
            'attention. The hook only sends notifications from Motif '
            'terminals.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              key: ValueKey('install-${agent.name}-hook-from-prompt'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Install'),
            ),
          ],
        ),
      );
      if (install != true || !mounted) return;

      installRequested = true;
      final installed = await _runtime.installCodingAgentHook(
        widget.serverId,
        agent,
      );
      if (!installed) {
        throw StateError('${agent.label} hook was not added to its config');
      }
      if (mounted) showMotifToast(context, '${agent.label} hook installed');
    } catch (error, stackTrace) {
      Log.w(
        'coding-agent hook prompt failed agent=${agent.name}',
        name: 'motif.hooks',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted && installRequested) {
        showMotifToast(
          context,
          'Could not install the ${agent.label} hook: $error',
          duration: const Duration(seconds: 4),
        );
      }
    } finally {
      _codingAgentHookCheckInFlight = false;
    }
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
    // A socket failure moves the workspace into reconnecting before _newPty
    // completes. The connection overlay already communicates that state; the
    // next attached transition invokes this method again, so avoid showing a
    // redundant transient toast for the failed automatic attempt.
    creation = _newPty(quietWhileReconnecting: true).whenComplete(() {
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
    final sessionDisplayName =
        widget.titleOverride ??
        _runtime.sessionDisplayName(widget.serverId, widget.session);
    if (widget.workspaceActive && _lastWindowTitle != sessionDisplayName) {
      _lastWindowTitle = sessionDisplayName;
      unawaited(MotifWindowTitle.set(sessionDisplayName).catchError((_) {}));
    }
    final c = context.motif;
    final fontSize = _runtime.terminalFontSize;
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
    final sidebar = _runtime.sidebar;
    final sidebarState = (
      showSessions: widget.allowSessionSwitching && sidebar.showSessions,
      showFileTree: sidebar.showFileTree,
      showGitDiff: sidebar.showGitDiff,
      showBottomBar: sidebar.showBottomBar,
      hasVisiblePanel:
          (widget.allowSessionSwitching && sidebar.showSessions) ||
          sidebar.showFileTree ||
          sidebar.showGitDiff,
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
          title: sessionDisplayName,
          color: c.accent,
          child: Scaffold(
            key: _scaffoldKey,
            resizeToAvoidBottomInset: false,
            drawer: usesSidebar || !widget.allowSessionSwitching
                ? null
                : Drawer(
                    key: const ValueKey('mobile-sessions-drawer'),
                    width: math.min(
                      constraints.maxWidth * 0.88,
                      _mobileDrawerMaxWidth,
                    ),
                    backgroundColor: c.surface,
                    child: SafeArea(
                      child: ObservationSelect(
                        selector: () => _connectedSessionsSelectKey(_runtime),
                        builder: (context, _, _) => _ConnectedSessionsPanel(
                          runtime: _runtime,
                          currentServerId: widget.serverId,
                          currentSession: widget.session,
                          onCloseAll: _closeAllSessionsFromMobileDrawer,
                          onSessionSelected: (serverId, session) =>
                              _switchSessionFromMobileDrawer(serverId, session),
                        ),
                      ),
                    ),
                  ),
            endDrawer: usesSidebar
                ? null
                : Drawer(
                    key: ValueKey(switch (_mobileEndDrawerPanel) {
                      _MobileEndDrawerPanel.files => 'mobile-files-drawer',
                      _MobileEndDrawerPanel.gitDiff => 'mobile-git-diff-drawer',
                    }),
                    width: math.min(
                      constraints.maxWidth * 0.88,
                      _mobileDrawerMaxWidth,
                    ),
                    backgroundColor: c.surface,
                    child: SafeArea(
                      child: switch (_mobileEndDrawerPanel) {
                        _MobileEndDrawerPanel.files => FileTreePanel(
                          key: ValueKey(
                            'mobile-drawer-files-${_fileTreeRoot ?? _workspaceApi.activeCwd()}',
                          ),
                          root:
                              _fileTreeRoot ?? _workspaceApi.activeCwd() ?? '~',
                          workspace: _workspaceApi,
                          embedded: true,
                          onOpen: _openPreviewFromMobileDrawer,
                        ),
                        _MobileEndDrawerPanel.gitDiff => GitDiffPanel(
                          key: ValueKey(
                            'mobile-drawer-diff-${_workspaceApi.activeCwd()}',
                          ),
                          cwd: _workspaceApi.activeCwd(),
                          workspace: _workspaceApi,
                          embedded: true,
                          onOpenDiff: _openDiffFromMobileDrawer,
                        ),
                      },
                    ),
                  ),
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
                  : Text(sessionDisplayName),
              titleSpacing: usesSidebar ? 0 : null,
              toolbarHeight: usesSidebar ? 52 : null,
              leadingWidth: usesSidebar && widget.allowSessionSwitching
                  ? 104
                  : null,
              leading: !widget.allowSessionSwitching
                  ? const BackButton()
                  : usesSidebar
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
                          onPressed: _toggleSessionsPanel,
                        ),
                      ],
                    )
                  : Center(
                      child: SizedBox(
                        width: MotifControlSize.md,
                        height: MotifControlSize.md,
                        child: IconButton(
                          key: const ValueKey('session-menu-button'),
                          icon: const Icon(Icons.menu),
                          tooltip: 'Sessions',
                          onPressed: _toggleSessionsPanel,
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
                ObservationSelect(
                  selector: () => _workspaceState.connection.isAttached,
                  builder: (context, attached, _) =>
                      attached && _workspaceApi.canCaptureScreen
                      ? IconButton(
                          key: const ValueKey('screen-capture-button'),
                          icon: const Icon(Icons.screenshot_monitor_outlined),
                          tooltip: 'Capture server screen',
                          onPressed: _showScreenCapture,
                        )
                      : const SizedBox.shrink(),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Terminal settings',
                  onPressed: () => unawaited(
                    _runtime.openTerminalSettings(
                      context,
                      serverId: widget.serverId,
                    ),
                  ),
                ),
              ],
            ),
            body: _AnimatedSidebarLayout(
              visible: showSidebar,
              width: sidebarWidth,
              sidebar: ObservationSelect(
                selector: _workspaceApi.activeCwd,
                builder: (context, cwd, _) => _SessionSidebar(
                  runtime: _runtime,
                  showSessions: sidebarState.showSessions,
                  showFileTree: sidebarState.showFileTree,
                  showDiff: sidebarState.showGitDiff,
                  currentServerId: widget.serverId,
                  currentSession: widget.session,
                  root: _fileTreeRoot ?? cwd ?? '~',
                  cwd: cwd,
                  workspace: _workspaceApi,
                  onSessionSelected: _switchSession,
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
                                  onOpenTerminalFile: _openTerminalFile,
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
                            final runningProgram = snap.runningProgram;
                            final inputState = _inputStateForView(
                              snap.activeViewId,
                            );
                            return ObservationSelect(
                              selector: () =>
                                  _runtime.resolvedCommands(runningProgram),
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
                                          onEdit: () => unawaited(
                                            _runtime.openQuickCommandEditor(
                                              context,
                                              setId: _runtime
                                                  .effectiveCommandSetId(
                                                    runningProgram,
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
