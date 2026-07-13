// Desktop Motif entrypoint. This is the only Flutter target that imports the
// embedded motifd server and native desktop shell implementations.
import 'dart:async';

import 'motif/bootstrap.dart';
import 'motif/platform/desktop_window.dart';
import 'motif/platform/desktop_window_desktop.dart';
import 'motif/platform/tray_service_desktop.dart' as desktop_tray;
import 'motif/platform/window_title_desktop.dart';
import 'motif/state/embedded_server_service_desktop.dart';
import 'motif/state/motif_runtime.dart';
import 'motif/state/server_connection_runtime.dart';
import 'motif/update/desktop_update_service.dart';
import 'motif/ui/app.dart' show motifNavigatorKey;
import 'motif/ui/screens/embedded_server_settings_sheet_desktop.dart'
    as desktop_server;
import 'motif/ui/widgets/desktop_update_dialog.dart';

Future<void> main() {
  installDesktopWindowDelegate();
  installDesktopWindowTitleDelegate();
  final updates = DesktopUpdateService();
  return runMotif(
    embeddedServerFactory: createDesktopEmbeddedServerService,
    clientRuntime: const DesktopMotifClientRuntime(),
    serverConnectionRuntime: const DesktopServerConnectionRuntime(),
    embeddedServerPageFactory: () => const desktop_server.EmbeddedServerPage(),
    desktopUpdateService: updates,
    afterFirstFrame: (appState) {
      updates.start(
        onUpdateAvailable: (update) async {
          final context = motifNavigatorKey.currentContext;
          if (context == null) return;
          await showDesktopUpdateDialog(
            context,
            update,
            onSkipVersion: () => updates.skipVersion(update),
          );
        },
      );
      if (desktop_tray.TrayService.isSupported &&
          (appState.embeddedServer?.available ?? false)) {
        unawaited(desktop_tray.TrayService(appState).start());
        unawaited(DesktopWindow.showAtLaunch());
      }
    },
  );
}
