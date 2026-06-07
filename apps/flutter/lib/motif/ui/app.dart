import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/settings.dart';
import '../state/app_state.dart';
import '../state/motif_client.dart';
import 'screens/connection_screen.dart';
import 'screens/session_list_screen.dart';
import 'screens/welcome_screen.dart';
import 'theme/motif_theme.dart';
import 'widgets/adaptive_modal.dart';
import 'widgets/notification_banner.dart';

final motifRouteObserver = RouteObserver<ModalRoute<void>>();

class MotifApp extends StatelessWidget {
  const MotifApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final terminalTheme = context.select<AppState, TerminalThemeSetting>(
      (a) => a.terminalSettings.settings.theme,
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
      navigatorObservers: [motifRouteObserver],
      home: app.hasActiveServer ? const _Root() : const WelcomeScreen(),
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
      await app.connectServerAndRefresh(server.id, makeActive: false);
    } catch (_) {
      // The client exposes connection failure state; startup should not block UI.
    }
  }

  @override
  Widget build(BuildContext context) => NotificationBannerHost(
    app: context.watch<AppState>(),
    child: const SessionListScreen(),
  );
}

/// Shared helper to open the connection/server manager as an adaptive
/// modal (bottom sheet on phones, dialog on desktop).
void openConnectionManager(BuildContext context) {
  showAdaptivePanel<void>(context, builder: (_) => const ConnectionScreen());
}
