import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/settings.dart';
import '../platform/desktop_window.dart';
import '../state/app_state.dart';
import '../state/motif_client.dart';
import 'screens/connection_screen.dart';
import 'screens/session_list_screen.dart';
import 'screens/session_screen.dart';
import 'screens/welcome_screen.dart';
import 'theme/motif_theme.dart';
import 'widgets/adaptive_modal.dart';
import 'widgets/notification_banner.dart';
import 'widgets/top_toast.dart';

final motifRouteObserver = RouteObserver<ModalRoute<void>>();

/// Navigator key so non-widget code (the system tray) can open dialogs/screens
/// against a live context.
final motifNavigatorKey = GlobalKey<NavigatorState>();

typedef EmbeddedServerPageFactory = Widget Function();

const double _desktopTitleBarHeight = 38;

Widget _emptyEmbeddedServerPage() => const SizedBox.shrink();

class MotifApp extends StatelessWidget {
  const MotifApp({
    super.key,
    this.embeddedServerPageFactory = _emptyEmbeddedServerPage,
  });

  final EmbeddedServerPageFactory embeddedServerPageFactory;

  @override
  Widget build(BuildContext context) {
    final terminalTheme = context.select<AppState, TerminalThemeSetting>(
      (a) => a.terminalSettings.settings.theme,
    );
    // With the desktop shell, the client lives under a nested Navigator that
    // owns `motifRouteObserver` (so the session list still gets didPopNext). A
    // RouteObserver can only be attached to one Navigator, so the root one
    // drops it in that case. Without the shell, the client is on the root
    // Navigator and keeps the observer.
    final canServe = context.select<AppState, bool>(
      (a) => a.embeddedServer?.available ?? false,
    );
    return MaterialApp(
      title: 'Motif',
      debugShowCheckedModeBanner: false,
      theme: motifTheme(Brightness.light),
      darkTheme: motifTheme(Brightness.dark),
      themeMode: switch (terminalTheme) {
        TerminalThemeSetting.light => ThemeMode.light,
        TerminalThemeSetting.dark => ThemeMode.dark,
        TerminalThemeSetting.system => ThemeMode.system,
      },
      navigatorKey: motifNavigatorKey,
      navigatorObservers: canServe ? const [] : [motifRouteObserver],
      builder: (context, child) {
        final app = context.read<AppState>();
        return MotifToastHost(
          child: NotificationBannerHost(
            app: app,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      // ⌘W (⌃W off macOS) hides the window to the tray; ⌘Q terminates the
      // complete macOS app. In the session view the terminal's own handler
      // claims ⌘W first (close tab) — this only fires on the screens that don't,
      // plus the session view's last-tab fallback.
      //
      // CallbackShortcuts is focus-based: its onKeyEvent only runs when the
      // primary focus is a descendant. The plain screens (session list, welcome,
      // connection) have no widget that grabs focus, and with the desktop shell's
      // nested navigator the default focus sits on the root route's scope — an
      // *ancestor* of CallbackShortcuts — so ⌘W never reached it. The autofocus
      // Focus anchors primary focus inside this subtree so the binding fires.
      home: CallbackShortcuts(
        bindings: _desktopWindowShortcuts(context),
        child: Focus(
          autofocus: true,
          child: _HomeShell(
            embeddedServerPageFactory: embeddedServerPageFactory,
          ),
        ),
      ),
    );
  }
}

/// Desktop lifecycle shortcuts: ⌘W hides on macOS (⌃W elsewhere), while ⌘Q
/// terminates the complete macOS app.
///
/// In the session view the terminal's own (global [HardwareKeyboard]) handler
/// runs first and claims ⌘W to close the active tab — but Flutter still fires
/// this focus-based binding afterward, so it would hide the window on top of
/// the tab close. The session handler flags that case via
/// [AppState.markCloseShortcutConsumed]; we read-and-clear it here and skip the
/// hide. On the plain screens (session list, welcome, connection) the session
/// handler never runs, the flag stays clear, and ⌘W hides the window.
Map<ShortcutActivator, VoidCallback> _desktopWindowShortcuts(
  BuildContext context,
) {
  final isMac = defaultTargetPlatform == TargetPlatform.macOS;
  return {
    SingleActivator(LogicalKeyboardKey.keyW, meta: isMac, control: !isMac): () {
      if (context.read<AppState>().takeCloseShortcutConsumed()) return;
      unawaited(DesktopWindow.hide());
    },
    if (isMac)
      const SingleActivator(LogicalKeyboardKey.keyQ, meta: true): () {
        unawaited(DesktopWindow.quit());
      },
  };
}

/// Top-level desktop shell. When this machine can run an embedded server, a
/// slim toolbar lets the user switch between the **client** (sessions) and the
/// **server** control panel; the two are kept alive side-by-side so switching
/// preserves state. On mobile / when no embedded server is available, the
/// client is shown directly (unchanged behavior, no toolbar).
class _HomeShell extends StatelessWidget {
  const _HomeShell({required this.embeddedServerPageFactory});

  final EmbeddedServerPageFactory embeddedServerPageFactory;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final canServe = app.embeddedServer?.available ?? false;
    if (!canServe) {
      if (!DesktopWindow.usesCustomTitleBar) return const _ClientHome();
      return const Column(
        children: [
          _CustomTitleBarSpacer(),
          Expanded(child: _ClientHome()),
        ],
      );
    }

    return Column(
      children: [
        _ModeToolbar(mode: app.viewMode, onChanged: app.setViewMode),
        Expanded(
          child: IndexedStack(
            index: app.viewMode == AppViewMode.server ? 1 : 0,
            children: [
              // The client keeps its own Navigator so pushing a session screen
              // stays inside this pane (under the toolbar) instead of covering
              // the whole window.
              const _ClientNavigator(),
              embeddedServerPageFactory(),
            ],
          ),
        ),
      ],
    );
  }
}

/// The client content: the grouped session browser once a server is configured,
/// otherwise the first-run welcome screen.
class _ClientHome extends StatelessWidget {
  const _ClientHome();

  @override
  Widget build(BuildContext context) {
    final hasServer = context.select<AppState, bool>((a) => a.hasActiveServer);
    return _PendingSessionOpenListener(
      child: hasServer ? const _Root() : const WelcomeScreen(),
    );
  }
}

/// Nested navigator hosting the client pane in the desktop shell.
class _ClientNavigator extends StatelessWidget {
  const _ClientNavigator();

  @override
  Widget build(BuildContext context) {
    return Navigator(
      observers: [motifRouteObserver],
      onGenerateRoute: (settings) =>
          MaterialPageRoute<void>(builder: (_) => const _ClientHome()),
    );
  }
}

class _CustomTitleBarSpacer extends StatelessWidget {
  const _CustomTitleBarSpacer();

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Material(
      color: c.surface,
      elevation: 0,
      child: Container(
        height: _desktopTitleBarHeight,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: const _WindowDragArea(),
      ),
    );
  }
}

/// Slim top toolbar carrying the compact Client/Server switch.
class _ModeToolbar extends StatelessWidget {
  const _ModeToolbar({required this.mode, required this.onChanged});

  final AppViewMode mode;
  final ValueChanged<AppViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    // On macOS the toolbar IS the (custom) title bar: inset the left to clear
    // the traffic-light buttons, and let the empty area drag the window.
    final customTitleBar = DesktopWindow.usesCustomTitleBar;
    return Material(
      color: c.surface,
      elevation: 0,
      child: Container(
        height: _desktopTitleBarHeight,
        padding: EdgeInsets.only(
          left: customTitleBar ? 78 : MotifSpacing.sm,
          right: MotifSpacing.sm,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Row(
          children: [
            // Drag region (macOS) / spacer fills the left, pushing the switch
            // to the right edge of the title bar.
            Expanded(
              child: customTitleBar
                  ? const _WindowDragArea()
                  : const SizedBox.shrink(),
            ),
            _ModeSwitch(mode: mode, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

/// Fills the title-bar's empty space; a pointer-down there starts a window
/// move (macOS custom title bar).
class _WindowDragArea extends StatelessWidget {
  const _WindowDragArea();

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => DesktopWindow.startDrag(),
      child: const SizedBox.expand(),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final AppViewMode mode;
  final ValueChanged<AppViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      decoration: BoxDecoration(
        color: c.subtleFill,
        borderRadius: BorderRadius.circular(MotifRadius.xs),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(c, Icons.terminal_rounded, 'Client', AppViewMode.client),
          _seg(c, Icons.dns_rounded, 'Server', AppViewMode.server),
        ],
      ),
    );
  }

  Widget _seg(MotifColors c, IconData icon, String label, AppViewMode m) {
    final selected = mode == m;
    // No Tooltip: the segment already shows its label, and the tooltip's dark
    // bubble flashes over the title bar on hover/click. GestureDetector (not
    // InkWell) so there's no ink ripple either — the selected pill is the only
    // feedback.
    return MouseRegion(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? c.background : Colors.transparent,
            borderRadius: BorderRadius.circular(MotifRadius.xs),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: selected ? c.accent : c.textTertiary),
              const SizedBox(width: 5),
              Text(
                label,
                style: MotifType.caption.copyWith(
                  color: selected ? c.textPrimary : c.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Once a server is configured, show the grouped session browser. Servers are
/// connected explicitly from the connection manager.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _autoConnectStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_autoConnectActiveServer());
    });
  }

  Future<void> _autoConnectActiveServer() async {
    if (_autoConnectStarted) return;
    _autoConnectStarted = true;
    final app = context.read<AppState>();
    final server = app.servers.activeServer;
    if (server == null) return;
    if (!app.shouldAutoConnectServer(server.id)) return;
    final state = app.serverState(server.id);
    if (state is ConnConnected ||
        state is ConnAttached ||
        state is ConnConnecting) {
      return;
    }
    try {
      await app.ensureServerConnectedAndRefresh(server.id, makeActive: false);
    } catch (_) {
      // The client exposes connection failure state; startup should not block UI.
    }
  }

  @override
  Widget build(BuildContext context) => const SessionListScreen();
}

/// Watches [AppState.pendingSessionOpen] and pushes [SessionScreen] on the
/// nearest navigator (the nested client navigator on desktop, the root one
/// elsewhere). Stays mounted under the home route so taps from a live session
/// still navigate.
class _PendingSessionOpenListener extends StatefulWidget {
  const _PendingSessionOpenListener({required this.child});

  final Widget child;

  @override
  State<_PendingSessionOpenListener> createState() =>
      _PendingSessionOpenListenerState();
}

class _PendingSessionOpenListenerState
    extends State<_PendingSessionOpenListener> {
  AppState? _app;
  bool _opening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppState>();
    if (!identical(_app, app)) {
      _app?.removeListener(_onAppChanged);
      _app = app;
      _app!.addListener(_onAppChanged);
    }
    _scheduleOpen();
  }

  @override
  void dispose() {
    _app?.removeListener(_onAppChanged);
    super.dispose();
  }

  void _onAppChanged() => _scheduleOpen();

  void _scheduleOpen() {
    if (!mounted || _opening || _app?.pendingSessionOpen == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openPending());
    });
  }

  Future<void> _openPending() async {
    final app = _app;
    if (app == null || _opening) return;
    final pending = app.takePendingSessionOpen();
    if (pending == null) return;
    _opening = true;
    try {
      final routeName = sessionRouteName(pending.serverId, pending.session);
      if (_topRouteName() == routeName) return;

      if (app.serverById(pending.serverId) == null) return;

      if (app.servers.activeId != pending.serverId) {
        await app.servers.setActive(pending.serverId);
        if (!mounted) return;
      }

      final connected = await app.ensureServerConnectedAndRefresh(
        pending.serverId,
        makeActive: false,
      );
      if (!mounted) return;
      if (!connected) {
        showMotifToast(context, 'Could not connect to the notification server');
        return;
      }
      app.clientForSession(pending.serverId, pending.session);
      // The visible route may have changed while the connection was opening.
      final topRouteName = _topRouteName();
      if (topRouteName == routeName) return;

      final nav = Navigator.of(context);
      final route = MaterialPageRoute<void>(
        settings: RouteSettings(name: routeName),
        builder: (_) =>
            SessionScreen(serverId: pending.serverId, session: pending.session),
      );
      if (topRouteName?.startsWith('session/') ?? false) {
        unawaited(nav.pushReplacement<void, void>(route));
      } else {
        unawaited(nav.push<void>(route));
      }
    } finally {
      _opening = false;
      // A second tap may have arrived while a connection was opening. Drain
      // the latest request now instead of waiting for an unrelated app event.
      _scheduleOpen();
    }
  }

  String? _topRouteName() {
    String? name;
    Navigator.of(context).popUntil((route) {
      name ??= route.settings.name;
      return true;
    });
    return name;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Shared helper to open the connection/server manager as an adaptive
/// modal (bottom sheet on phones, dialog on desktop).
void openConnectionManager(BuildContext context) {
  showAdaptivePanel<void>(context, builder: (_) => const ConnectionPanel());
}
