// Desktop Motif entrypoint. This is the only Flutter target that imports the
// embedded motifd server and native desktop shell implementations.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'motif/bootstrap.dart';
import 'motif/platform/desktop_window.dart';
import 'motif/platform/desktop_window_desktop.dart';
import 'motif/platform/secret_store.dart';
import 'motif/platform/tray_service_desktop.dart' as desktop_tray;
import 'motif/platform/window_title_desktop.dart';
import 'motif/state/embedded/embedded_server_service_desktop.dart';
import 'motif/state/workspace/terminal/terminal_runtime_policy.dart';
import 'motif/state/workspace/workspace_retention_policy.dart';
import 'motif/update/desktop_update_service.dart';
import 'motif/ui/app.dart' show motifNavigatorKey;
import 'motif/ui/screens/embedded_server_settings_sheet_desktop.dart'
    as desktop_server;
import 'motif/ui/widgets/desktop_update_dialog.dart';

Future<void> main() async {
  if (Platform.isMacOS &&
      Platform.environment['MOTIF_MACOS_RELEASE_PROBE'] == '1') {
    await _runMacosReleaseProbe();
    return;
  }

  installDesktopWindowDelegate();
  installDesktopWindowTitleDelegate();
  final updates = DesktopUpdateService();
  await runMotif(
    embeddedServerFactory: createDesktopEmbeddedServerService,
    terminalRuntime: const DesktopTerminalRuntimePolicy(),
    workspaceRetentionPolicy: const DesktopWorkspaceRetentionPolicy(),
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

Future<void> _runMacosReleaseProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  final secrets = FlutterSecureSecretStore.macos();
  const key = 'motif.release.keychainProbe';
  final value = '${DateTime.now().microsecondsSinceEpoch}-$pid';

  try {
    await secrets.write(key, value);
    if (await secrets.read(key) != value) {
      throw StateError('Keychain read did not return the value just written');
    }
    await secrets.delete(key);
    if (await secrets.read(key) != null) {
      throw StateError('Keychain value remained after deletion');
    }
    stdout.writeln('Motif macOS release probe passed.');
    await stdout.flush();
    exit(0);
  } catch (error, stackTrace) {
    try {
      await secrets.delete(key);
    } catch (_) {}
    stderr.writeln('Motif macOS release probe failed: $error');
    stderr.writeln(stackTrace);
    await stderr.flush();
    exit(1);
  }
}
