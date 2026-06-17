// Default Motif entrypoint for web/mobile/client-only builds.
//
// Desktop packages use `lib/main_desktop.dart`, which opts into the embedded
// motifd server, tray, and native window glue explicitly.
import 'motif/bootstrap.dart';

Future<void> main() => runMotif();
