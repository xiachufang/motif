// Desktop Motif entrypoint. This is the only Flutter target that imports the
// embedded motifd server and native desktop shell implementations.
import 'dart:async';

import 'motif/bootstrap.dart';
import 'motif/platform/desktop_window.dart';
import 'motif/platform/desktop_window_desktop.dart';
import 'motif/platform/tray_service_desktop.dart' as desktop_tray;
import 'motif/platform/window_title_desktop.dart';
import 'motif/state/embedded_server_service_desktop.dart';
import 'motif/ui/app.dart';
import 'motif/ui/screens/embedded_server_settings_sheet_desktop.dart'
    as desktop_server;

Future<void> main() {
  installDesktopWindowDelegate();
  installDesktopWindowTitleDelegate();
  installEmbeddedServerPageFactory(
    () => const desktop_server.EmbeddedServerPage(),
  );

  return runMotif(
    embeddedServerFactory: createDesktopEmbeddedServerService,
    afterFirstFrame: (appState) {
      if (desktop_tray.TrayService.isSupported &&
          (appState.embeddedServer?.available ?? false)) {
        unawaited(desktop_tray.TrayService(appState).start());
        unawaited(DesktopWindow.showAtLaunch());
      }
    },
  );
}
