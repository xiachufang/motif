import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'log/log.dart';
import 'platform/platform_factory.dart';
import 'platform/window_title.dart';
import 'state/app/app_state.dart';
import 'state/embedded/embedded_server_service.dart';
import 'state/workspace/terminal/terminal_runtime_policy.dart';
import 'state/app/motif_scope.dart';
import 'state/workspace/workspace_retention_policy.dart';
import 'update/desktop_update_service.dart';
import 'ui/app.dart';

typedef MotifStartupHook = FutureOr<void> Function(AppState appState);

/// Start the shared Motif Flutter app.
///
/// The default entrypoint passes no [embeddedServerFactory], so web/mobile and
/// client-only builds never pull the desktop embedded-server implementation
/// into the compile graph. Desktop builds opt in from `main_desktop.dart`.
Future<void> runMotif({
  EmbeddedServerFactory? embeddedServerFactory,
  TerminalRuntimePolicy? terminalRuntime,
  WorkspaceRetentionPolicy? workspaceRetentionPolicy,
  EmbeddedServerPageFactory? embeddedServerPageFactory,
  DesktopUpdateService? desktopUpdateService,
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
            terminalRuntime: terminalRuntime,
            workspaceRetentionPolicy: workspaceRetentionPolicy,
          );
          final embedded = appState.embeddedServer;
          runApp(
            MotifScope(
              appState: appState,
              embeddedServer: embedded,
              desktopUpdateService: desktopUpdateService,
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
