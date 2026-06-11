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

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:nativeapi/nativeapi.dart' as na;

import '../state/app_state.dart';
import '../state/embedded_server_service.dart';
import '../ui/screens/embedded_server_settings_sheet.dart';
import 'desktop_launch.dart';
import 'desktop_window.dart';
import 'tray_icons.g.dart';

class TrayService {
  final AppState _app;
  final GlobalKey<NavigatorState> _navigatorKey;

  na.TrayIcon? _tray;
  EmbeddedServerService? _svc;
  EmbeddedRunState? _lastPhase;
  bool _lastHasLoopback = false;
  // nativeapi can deliver a menu-item click more than once for a single
  // selection on macOS; this collapses rapid repeats to one action.
  DateTime? _lastActionAt;
  bool _settingsOpen = false;

  TrayService(this._app, this._navigatorKey);

  static bool get isSupported =>
      !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  /// Create the tray icon and start reflecting the embedded server's state.
  void start() {
    final svc = _app.embeddedServer;
    if (!isSupported || svc == null || !svc.available) return;
    _svc = svc;
    try {
      _tray = na.TrayIcon()
        ..tooltip = 'Motif'
        ..contextMenuTrigger = na.ContextMenuTrigger.clicked;
      _tray!.startEventListening();
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
    if (!force && phase == _lastPhase && hasLoopback == _lastHasLoopback) {
      return;
    }
    _lastPhase = phase;
    _lastHasLoopback = hasLoopback;
    _applyIcon(tray, phase);
    tray.tooltip = 'Motif — ${_phaseLabel(phase)}';
    tray.contextMenu = _buildMenu(svc);
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

  na.Menu _buildMenu(EmbeddedServerService svc) {
    final status = svc.status;
    final running = status.running;
    final starting = status.starting;
    final menu = na.Menu();

    if (running || starting) {
      menu.addItem(_item('Stop Server', () => svc.stop()));
    } else {
      menu.addItem(_item('Start Server', () => svc.start()));
    }

    if (running && status.loopbackEndpoint != null) {
      menu.addSeparator();
      menu.addItem(_item('Open in Browser…', () => _openWebUi(svc)));
    }
    if (status.authUrl != null) {
      menu.addItem(
        _item('Sign in to Tailscale…', () {
          openExternalUrl(status.authUrl!);
        }),
      );
    }

    menu.addSeparator();
    menu.addItem(_item('Open Settings…', _openSettings));
    menu.addItem(_item('Show Motif', () => DesktopWindow.show()));
    menu.addSeparator();
    menu.addItem(_item('Quit Motif', _quit));
    return menu;
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
      onTap();
    });
    return item;
  }

  /// Open the running server's served web UI in the default browser, with the
  /// auth token appended so it auto-connects (mirrors the menu-bar app).
  void _openWebUi(EmbeddedServerService svc) {
    final ep = svc.status.loopbackEndpoint;
    if (ep == null) return;
    var url = 'http://${ep.host}:${ep.port}/';
    final token = svc.config.authEnabled ? svc.config.authToken.trim() : '';
    if (token.isNotEmpty) {
      url = '$url?token=${Uri.encodeQueryComponent(token)}';
    }
    openExternalUrl(url);
  }

  Future<void> _openSettings() async {
    if (_settingsOpen) return; // already showing — don't stack a second sheet.
    _settingsOpen = true;
    try {
      await DesktopWindow.show();
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await showEmbeddedServerSettingsSheet(ctx);
      }
    } finally {
      _settingsOpen = false;
    }
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
