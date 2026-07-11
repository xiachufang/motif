import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'log/log.dart';
import 'platform/platform_factory.dart';
import 'platform/window_title.dart';
import 'state/app_state.dart';
import 'state/embedded_server_service.dart';
import 'state/motif_runtime.dart';
import 'state/server_connection_runtime.dart';
import 'ui/app.dart';

typedef MotifStartupHook = FutureOr<void> Function(AppState appState);

/// Start the shared Motif Flutter app.
///
/// The default entrypoint passes no [embeddedServerFactory], so web/mobile and
/// client-only builds never pull the desktop embedded-server implementation
/// into the compile graph. Desktop builds opt in from `main_desktop.dart`.
Future<void> runMotif({
  EmbeddedServerFactory? embeddedServerFactory,
  MotifClientRuntime? clientRuntime,
  ServerConnectionRuntime? serverConnectionRuntime,
  EmbeddedServerPageFactory? embeddedServerPageFactory,
  MotifStartupHook? afterFirstFrame,
}) {
  return runZonedGuarded<Future<void>>(
        () async {
          WidgetsFlutterBinding.ensureInitialized();
          // Console + rotating file logging (file is native-only; web is
          // console-only).
          await Log.init();
          await MotifWindowTitle.ensureInitialized();

          // Framework errors (build/layout/paint). Still print to console after
          // logging.
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
            return true; // handled; don't crash the app.
          };

          // Native: real libtailscale service when its dylib is present; web:
          // no-op.
          final appState = await AppState.load(
            platform: makePlatformServices(),
            embeddedServerFactory: embeddedServerFactory,
            clientRuntime: clientRuntime,
            serverConnectionRuntime: serverConnectionRuntime,
          );
          final embedded = appState.embeddedServer;
          runApp(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<AppState>.value(value: appState),
                // Desktop installs this provider from `main_desktop.dart`.
                if (embedded != null)
                  ChangeNotifierProvider<EmbeddedServerService>.value(
                    value: embedded,
                  ),
              ],
              child: MotifApp(
                embeddedServerPageFactory:
                    embeddedServerPageFactory ?? _emptyServerPage,
              ),
            ),
          );

          if (afterFirstFrame != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              unawaited(Future<void>.sync(() => afterFirstFrame(appState)));
            });
          }
        },
        (error, stack) {
          // Uncaught async errors that escape the zone (incl. failures during
          // startup).
          Log.e(
            'uncaught zone error',
            name: 'motif.crash',
            error: error,
            stackTrace: stack,
          );
        },
      ) ??
      Future<void>.value();
}

Widget _emptyServerPage() => const SizedBox.shrink();
