// Motif app entrypoint. Run with `flutter run` (this is the default target).
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'motif/log/log.dart';
import 'motif/platform/platform_factory.dart';
import 'motif/platform/desktop_window.dart';
import 'motif/platform/tray_service.dart';
import 'motif/platform/window_title.dart';
import 'motif/state/app_state.dart';
import 'motif/state/embedded_server_service.dart';
import 'motif/ui/app.dart';

Future<void> main() async {
  // All startup + the app run inside one guarded zone so framework, platform,
  // and async errors all reach the logger (console + rotating file).
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Console + rotating file logging (file is native-only; web is console-only).
      await Log.init();
      await MotifWindowTitle.ensureInitialized();

      // Framework errors (build/layout/paint). Still print to console after logging.
      FlutterError.onError = (details) {
        Log.e(
          'FlutterError: ${details.exceptionAsString()}',
          name: 'motif.crash',
          error: details.exception,
          stackTrace: details.stack,
        );
        FlutterError.presentError(details);
      };
      // Uncaught errors from the engine/platform side (e.g. in callbacks).
      PlatformDispatcher.instance.onError = (error, stack) {
        Log.e(
          'uncaught platform error',
          name: 'motif.crash',
          error: error,
          stackTrace: stack,
        );
        return true; // handled — don't crash the app.
      };

      // Native: real libtailscale service when its dylib is present; web: no-op.
      final appState = await AppState.load(platform: makePlatformServices());
      final embedded = appState.embeddedServer;
      runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: appState),
            // The embedded server is its own provider so the Server view + tray
            // consume it directly, not through AppState. Only present on desktop
            // where the native library loaded.
            if (embedded != null)
              ChangeNotifierProvider<EmbeddedServerService>.value(
                value: embedded,
              ),
          ],
          child: const MotifApp(),
        ),
      );

      // Desktop: live in the tray (start the embedded-server tray control and
      // start hidden, accessory-style). No-op when the embedded server isn't
      // available, so the window stays shown on platforms without it.
      if (TrayService.isSupported && (appState.embeddedServer?.available ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          TrayService(appState).start();
          unawaited(DesktopWindow.hideAtLaunch());
        });
      }
    },
    (error, stack) {
      // Uncaught async errors that escape the zone (incl. failures during startup).
      Log.e(
        'uncaught zone error',
        name: 'motif.crash',
        error: error,
        stackTrace: stack,
      );
    },
  );
}
