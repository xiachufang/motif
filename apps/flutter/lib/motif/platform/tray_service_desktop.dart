/// System-tray control for the embedded server (desktop only) — the Flutter
/// equivalent of the Tauri menu-bar app's tray. Shows a status icon and a menu
/// to Start/Stop the in-process server, open the served web UI, reach the
/// settings screen, show the main window, and quit. Reflects the embedded
/// server's run state in the icon + menu, rebuilding only when the state
/// changes.
///
/// No-op when there's no embedded-server capability (web/mobile, or the native
/// library failed to load).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nativeapi/nativeapi.dart' as na;

import '../state/app_state.dart';
import '../state/embedded_server_service.dart';
import 'desktop_launch_desktop.dart';
import 'desktop_window.dart';
import 'tray_icons.g.dart';

class TrayService {
  final AppState _app;

  na.TrayIcon? _tray;
  // The single context menu, created once and mutated in place. It is never
  // reassigned (see _populateMenu for why).
  na.Menu? _menu;
  // Current menu items, retained so their click-event closures aren't GC'd.
  final List<na.MenuItem> _items = [];
  EmbeddedServerService? _svc;
  EmbeddedRunState? _lastPhase;
  bool _lastHasLoopback = false;
  bool _lastHasAuth = false;
  // nativeapi can deliver a menu-item click more than once for a single
  // selection on macOS; this collapses rapid repeats to one action.
  DateTime? _lastActionAt;

  TrayService(this._app);

  static bool get isSupported =>
      !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  /// Create the tray icon and start reflecting the embedded server's state.
  Future<void> start() async {
    final svc = _app.embeddedServer;
    if (!isSupported || svc == null || !svc.available) return;
    _svc = svc;
    // Destroy any tray left over from a previous isolate (a hot restart) before
    // creating a fresh one — otherwise the stale tray accumulates and clicking
    // it invokes a deleted FFI callback (a crash). No-op on a cold launch.
    await DesktopWindow.cleanupStaleTray();
    try {
      final tray = na.TrayIcon()
        ..tooltip = 'Motif'
        ..contextMenuTrigger = na.ContextMenuTrigger.rightClicked;
      tray.on<na.TrayIconClickedEvent>((_) {
        unawaited(_showView(AppViewMode.client));
      });
      _tray = tray;
      // Create the context menu once and bind it now. Everything after this
      // mutates this same Menu object in place (see _populateMenu).
      final menu = na.Menu();
      _menu = menu;
      tray.contextMenu = menu;
      // Remember this tray's native handle so the next isolate can clean it up.
      unawaited(DesktopWindow.stashTrayHandle(tray.nativeHandle.address));
    } catch (_) {
      _tray = null;
      return;
    }
    svc.addListener(_sync);
    _sync(force: true);
  }

  void dispose() {
    _svc?.removeListener(_sync);
    try {
      _tray?.dispose();
    } catch (_) {}
    _tray = null;
  }

  void _sync({bool force = false}) {
    final tray = _tray;
    final svc = _svc;
    if (tray == null || svc == null) return;
    final phase = svc.status.phase;
    final hasLoopback = svc.status.loopbackEndpoint != null;
    final hasAuth = svc.status.authUrl != null;
    if (!force &&
        phase == _lastPhase &&
        hasLoopback == _lastHasLoopback &&
        hasAuth == _lastHasAuth) {
      return;
    }
    _lastPhase = phase;
    _lastHasLoopback = hasLoopback;
    _lastHasAuth = hasAuth;
    _applyIcon(tray, phase);
    tray.tooltip = 'Motif — ${_phaseLabel(phase)}';
    _populateMenu(svc);
  }

  void _applyIcon(na.TrayIcon tray, EmbeddedRunState phase) {
    // needs-login is reflected when running but Tailscale is waiting on auth.
    final b64 = switch (phase) {
      EmbeddedRunState.running =>
        _svc!.status.authUrl != null ? TrayIcons.error : TrayIcons.running,
      EmbeddedRunState.starting => TrayIcons.starting,
      EmbeddedRunState.failed => TrayIcons.error,
      EmbeddedRunState.stopped => TrayIcons.stopped,
    };
    // Some platforms' decoder wants a data URI; try both.
    var img = na.Image.fromBase64(b64);
    img ??= na.Image.fromBase64('data:image/png;base64,$b64');
    if (img != null) {
      tray.icon = img;
      tray.title = null;
    } else {
      // Fallback so the status item is at least visible/clickable.
      tray.title = 'Motif';
    }
    tray.isVisible = true;
  }

  String _phaseLabel(EmbeddedRunState phase) => switch (phase) {
    EmbeddedRunState.running => 'Running',
    EmbeddedRunState.starting => 'Starting…',
    EmbeddedRunState.failed => 'Failed',
    EmbeddedRunState.stopped => 'Stopped',
  };

  /// Repopulate the existing context menu *in place*. We never reassign
  /// `tray.contextMenu` after the initial bind: on macOS, `set_context_menu`
  /// detaches the close-listener nativeapi uses to reset the status item's
  /// native menu, so a menu swapped from inside a click handler leaves the old
  /// menu attached — and macOS keeps showing it (stale) on the next open.
  /// Mutating the same Menu object avoids that path entirely.
  void _populateMenu(EmbeddedServerService svc) {
    final menu = _menu;
    if (menu == null) return;
    while (menu.itemCount > 0) {
      menu.removeItemAt(0);
    }
    _items.clear();

    final status = svc.status;
    final running = status.running;
    final starting = status.starting;

    void add(na.MenuItem item) {
      _items.add(item);
      menu.addItem(item);
    }

    if (running || starting) {
      add(_item('Stop Server', () => svc.stop()));
    } else {
      add(_item('Start Server', () => svc.start()));
    }

    if (running && status.loopbackEndpoint != null) {
      menu.addSeparator();
      add(_item('Open in Browser…', () => _openWebUi(svc)));
    }
    if (status.authUrl != null) {
      add(
        _item('Sign in to Tailscale…', () => openExternalUrl(status.authUrl!)),
      );
    }

    menu.addSeparator();
    // Match the in-app Client/Server switch (lib/motif/ui/app.dart): each opens
    // the window on that view.
    add(_item('Open Client', () => _showView(AppViewMode.client)));
    add(_item('Open Server', () => _showView(AppViewMode.server)));
    menu.addSeparator();
    add(_item('Quit Motif', _quit));
  }

  na.MenuItem _item(String label, VoidCallback onTap) {
    final item = na.MenuItem(label);
    item.startEventListening();
    item.on<na.MenuItemClickedEvent>((_) {
      final now = DateTime.now();
      final last = _lastActionAt;
      if (last != null &&
          now.difference(last) < const Duration(milliseconds: 500)) {
        return; // duplicate click event for the same selection — ignore.
      }
      _lastActionAt = now;
      // Defer until the menu has closed: the action can change server state and
      // repopulate the menu (_populateMenu), and we'd rather not mutate the
      // items of a menu that's still on screen mid-dismiss.
      Future.delayed(const Duration(milliseconds: 50), onTap);
    });
    return item;
  }

  /// Open the running server's served web UI in the default browser. The
  /// loopback listener is plaintext and unauthenticated (LAN/relay pairing adds
  /// TLS + a bearer, which a browser can't pin — use the app/QR for those).
  void _openWebUi(EmbeddedServerService svc) {
    final ep = svc.status.loopbackEndpoint;
    if (ep == null) return;
    openExternalUrl('http://${ep.host}:${ep.port}/');
  }

  /// Switch the app to [mode] and bring the window forward.
  Future<void> _showView(AppViewMode mode) async {
    _app.setViewMode(mode);
    await DesktopWindow.show();
  }

  void _quit() {
    // Best-effort graceful stop before exiting, then terminate the process.
    final svc = _svc;
    if (svc != null && (svc.status.running || svc.status.starting)) {
      svc.stop();
    }
    exit(0);
  }
}
