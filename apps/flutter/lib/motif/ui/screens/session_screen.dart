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
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../log/log.dart';
import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../platform/desktop_window.dart';
import '../../platform/apple_input_document.dart';
import '../../platform/window_title.dart';
import '../../state/app_state.dart';
import '../../state/motif_client.dart';
import '../../state/sticky_modifiers.dart';
import '../../terminal/native_terminal.dart';
import '../../terminal/terminal_focus_policy.dart';
import '../../terminal/terminal_error_view.dart';
import '../../terminal/terminal_input.dart';
import '../../terminal/terminal_palette.dart';
import '../theme/motif_buttons.dart';
import '../theme/motif_theme.dart';
import '../widgets/quick_command_row.dart';
import '../widgets/top_toast.dart';
import 'change_directory_panel.dart';
import 'file_tree_panel.dart';
import 'git_diff_panel.dart';
import 'preview_pane.dart';
import 'quick_command_editor.dart';
import 'remote_port_webview_screen.dart';
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

/// The main terminal interface: tab bar of views + active pane + input bar.
/// Mirrors SessionView. PTY panes use the libghostty-backed renderer.
class SessionScreen extends StatefulWidget {
  final String serverId;
  final String session;
  const SessionScreen({
    super.key,
    required this.serverId,
    required this.session,
  });

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  static const double _sidebarBreakpoint = 768;
  static const double _sidebarMinWidth = 96;
  static const double _sidebarMaxWidthFraction = 0.6;
  static const double _mainMinWidth = 360;

  final StickyModifiers _modifiers = StickyModifiers();
  final Set<String> _mountedViewIds = <String>{};
  final Set<String> _appleInputDocumentIds = <String>{};
  final Map<String, _TabInputState> _tabInputs = <String, _TabInputState>{};
  late final _TabInputState _fallbackInput;
  final ValueNotifier<double> _keyboardInset = ValueNotifier(0);
  final ValueNotifier<double> _bottomBarContentHeight = ValueNotifier(
    _bottomBarCollapsedContentHeight,
  );
  DateTime? _lastKeyboardInsetLogAt;
  int _terminalFocusSerial = 0;
  bool _keyboardInsetSyncScheduled = false;
  bool _paneMountReady = false;
  bool _usesSidebarLayout = false;
  bool _switchingSession = false;
  bool _attachingSession = false;
  bool _recording = false;
  bool _micStarting = false;
  String? _lastAppleInputDocumentId;
  String _asrBase = '';
  String _lastAsrText = ''; // last value ASR wrote to the input bar
  String? _asrInputViewId;
  bool _ignoreFinal = false; // set when the user bailed out of ASR by typing

  @override
  void initState() {
    super.initState();
    _fallbackInput = _createInputState('fallback');
    WidgetsBinding.instance.addObserver(this);
    _scheduleKeyboardInsetSync();
    HardwareKeyboard.instance.addHandler(_handleShortcut);
    _syncWindowTitle();
    _attachIfNeeded();
  }

  /// Attach to [SessionScreen.session] if this client isn't already attached
  /// to it. Callers navigate here immediately and the attach round trips
  /// (RPC POST + /events WebSocket) happen behind a connecting overlay instead
  /// of blocking the page transition.
  void _attachIfNeeded() {
    final motif = context.read<AppState>().clientForServer(widget.serverId);
    // While the transport is down the reconnect flow owns reattaching
    // (intendedSession); attaching here would just throw "not connected".
    if (!motif.isLive) return;
    final state = motif.state;
    if (state is ConnAttached && state.session == widget.session) {
      // Already attached — this is a switch-back to a session kept warm in the
      // background. Reclaim the foreground so it reactivates its view and
      // re-advertises the terminal palette.
      motif.setForeground(true);
      return;
    }
    _attachingSession = true;
    unawaited(_attachToSession(motif));
  }

  Future<void> _attachToSession(MotifClient motif) async {
    final sw = Stopwatch()..start();
    try {
      await motif.attach(widget.session);
      Log.i(
        'open attach session=${widget.session} took=${sw.elapsedMilliseconds}ms',
        name: 'motif.ui',
      );
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mountPaneImmediately();
  }

  @override
  void didUpdateWidget(covariant SessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _syncWindowTitle();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keyboardInset.dispose();
    _bottomBarContentHeight.dispose();
    HardwareKeyboard.instance.removeHandler(_handleShortcut);
    for (final id in _appleInputDocumentIds) {
      unawaited(AppleInputDocument.dispose(id).catchError((_) {}));
    }
    _appleInputDocumentIds.clear();
    _disposeInputState(_fallbackInput);
    for (final input in _tabInputs.values) {
      _disposeInputState(input);
    }
    _tabInputs.clear();
    _modifiers.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _scheduleKeyboardInsetSync();
  }

  void _mountPaneImmediately() {
    if (_paneMountReady) return;
    _paneMountReady = true;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if ((media.viewInsets.bottom - _keyboardInset.value).abs() >= 0.5) {
      _scheduleKeyboardInsetSync();
    }
    final app = context.watch<AppState>();
    final motif = app.clientForServer(widget.serverId);
    final c = context.motif;
    final fontSize = app.terminalSettings.settings.fontSize;
    final terminalPalette = terminalPaletteForBrightness(
      Theme.of(context).brightness,
    );
    final sidebar = app.sessionSidebar;
    return LayoutBuilder(
      builder: (context, constraints) {
        final usesSidebar = constraints.maxWidth >= _sidebarBreakpoint;
        _usesSidebarLayout = usesSidebar;
        return Title(
          title: widget.session,
          color: c.accent,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              title: usesSidebar
                  ? _TabBar(motif: motif, onNewPty: _newPty, inTitleBar: true)
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
                          onPressed: () => _closeSession(motif),
                        ),
                        IconButton(
                          key: const ValueKey('sessions-sidebar-toggle'),
                          icon: const Icon(Icons.list_alt_outlined),
                          tooltip:
                              'Sessions (${_primaryShortcutLabel('L', shift: true)})',
                          style: _sidebarButtonStyle(c, sidebar.showSessions),
                          onPressed: () => _toggleSessionsPanel(app),
                        ),
                      ],
                    )
                  : Builder(
                      builder: (buttonContext) => IconButton(
                        icon: const Icon(Icons.menu),
                        tooltip: 'Session menu',
                        onPressed: () =>
                            _showSessionMenu(app, motif, buttonContext),
                      ),
                    ),
              actions: [
                IconButton(
                  key: const ValueKey('file-tree-sidebar-toggle'),
                  icon: const Icon(Icons.folder_outlined),
                  tooltip: 'Files (${_primaryShortcutLabel('E', shift: true)})',
                  style: _sidebarButtonStyle(
                    c,
                    usesSidebar && sidebar.showFileTree,
                  ),
                  onPressed: () => _toggleFileTree(motif),
                ),
                IconButton(
                  key: const ValueKey('git-diff-sidebar-toggle'),
                  icon: const Icon(Icons.difference_outlined),
                  tooltip:
                      'Git diff (${_primaryShortcutLabel('G', shift: true)})',
                  style: _sidebarButtonStyle(
                    c,
                    usesSidebar && sidebar.showGitDiff,
                  ),
                  onPressed: () => _toggleGitDiff(motif),
                ),
                if (usesSidebar)
                  IconButton(
                    key: const ValueKey('bottom-bar-toggle'),
                    icon: const Icon(Icons.keyboard_alt_outlined),
                    tooltip: 'Bottom bar',
                    style: _sidebarButtonStyle(c, sidebar.showBottomBar),
                    onPressed: () {
                      setState(() {
                        sidebar.showBottomBar = !sidebar.showBottomBar;
                      });
                    },
                  ),
                IconButton(
                  key: const ValueKey('open-remote-port-button'),
                  icon: const Icon(Icons.open_in_browser_outlined),
                  tooltip: 'Open remote port',
                  onPressed: motif.state is ConnAttached
                      ? () => _showRemotePortDialog(motif)
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Terminal settings',
                  onPressed: () => showTerminalSettingsSheet(context),
                ),
              ],
            ),
            body: ListenableBuilder(
              listenable: motif,
              builder: (context, _) {
                final connectionView = app.serverViewState(widget.serverId);
                final overlayMessage =
                    connectionView.terminalOverlay ??
                    (_attachingSession ? 'Connecting...' : null);
                final activeView = _switchingSession
                    ? null
                    : _activeView(motif);
                _reconcileTabInputs(motif, activeView);
                _syncAppleInputDocument(activeView?.id);
                final inputState = _inputStateForView(activeView?.id);
                final inputPtyId = _switchingSession
                    ? null
                    : _activePtyId(motif);
                final mountedViews = _paneMountReady
                    ? _mountedViews(motif, activeView)
                    : const <ViewInfo>[];
                final runningProgram = inputPtyId == null
                    ? null
                    : motif.runningCommand[inputPtyId];
                final commandStore = context.read<AppState>().commands;
                final showBottomBar = !usesSidebar || sidebar.showBottomBar;
                final bottomBar = _MeasureSize(
                  onChange: _setBottomBarContentSize,
                  child: ColoredBox(
                    color: c.background,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        QuickCommandRow(
                          commands: commandStore.resolved(runningProgram),
                          modifiers: _modifiers,
                          onSendBytes: (b) => _sendBytes(b),
                          onInsertText: _insertText,
                          onChangeDirectory: () => _openChangeDirectory(motif),
                          onEdit: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => QuickCommandEditor(
                                setId: commandStore.effectiveSetId(
                                  runningProgram,
                                ),
                              ),
                            ),
                          ),
                        ),
                        _InputBar(
                          key: ValueKey(
                            'bottom-input-${activeView?.id ?? 'fallback'}',
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
                final mainContent = Stack(
                  children: [
                    Column(
                      children: [
                        if (!usesSidebar)
                          _TabBar(motif: motif, onNewPty: _newPty),
                        Expanded(
                          child: ClipRect(
                            child: _BottomBarLiftedPane(
                              enabled: showBottomBar,
                              contentHeight: _bottomBarContentHeight,
                              child: _PaneStack(
                                activeView: activeView,
                                attaching: _attachingSession,
                                mountPanes: _paneMountReady,
                                mountedViews: mountedViews,
                                motif: motif,
                                fontSize: fontSize,
                                palette: terminalPalette,
                                focusSerial: _terminalFocusSerial,
                                keyboardInset: _keyboardInset,
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
                          child: bottomBar,
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
                );
                final showSidebar = usesSidebar && sidebar.hasVisiblePanel;
                final sidebarMaxWidth = math.max(
                  _sidebarMinWidth,
                  math.min(
                    constraints.maxWidth * _sidebarMaxWidthFraction,
                    constraints.maxWidth - _mainMinWidth,
                  ),
                );
                final sidebarWidth = sidebar.width
                    .clamp(_sidebarMinWidth, sidebarMaxWidth)
                    .toDouble();
                return _AnimatedSidebarLayout(
                  visible: showSidebar,
                  width: sidebarWidth,
                  sidebar: _SessionSidebar(
                    app: app,
                    showSessions: sidebar.showSessions,
                    showFileTree: sidebar.showFileTree,
                    showDiff: sidebar.showGitDiff,
                    currentServerId: widget.serverId,
                    currentSession: widget.session,
                    root: motif.activeCwd ?? '~',
                    cwd: motif.activeCwd,
                    motif: motif,
                    onSessionSelected: (serverId, session) =>
                        _switchSession(app, motif, serverId, session),
                    onOpenPreview: _openPreview,
                    splitFraction: sidebar.splitFraction,
                    onSplitChanged: (fraction) {
                      setState(() => sidebar.splitFraction = fraction);
                    },
                    firstSplitFraction: sidebar.firstSplitFraction,
                    onFirstSplitChanged: (fraction) {
                      setState(() => sidebar.firstSplitFraction = fraction);
                    },
                    secondSplitFraction: sidebar.secondSplitFraction,
                    onSecondSplitChanged: (fraction) {
                      setState(() => sidebar.secondSplitFraction = fraction);
                    },
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
                  mainContent: mainContent,
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Small pill shown over the terminal while the connection is being
/// re-established. Input is blocked in this state ([MotifClient.canInput]).
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
        boxShadow: [
          BoxShadow(
            color: c.shadow,
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
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
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
