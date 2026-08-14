import 'package:material_ui/material_ui.dart';

import '../../models/settings.dart';
import '../../state/app/app_state.dart';
import '../../state/app/motif_scope.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/top_toast.dart';
import 'rzv_scan_screen.dart';
import 'server_edit_sheet.dart';

typedef PairingScanLauncher =
    Future<RzvScanResult?> Function(BuildContext context);

enum _AddServerMethod { scan, manual }

/// Unified entry point for adding a server. The user first chooses camera
/// pairing or manual configuration; both paths return the same result so the
/// caller owns the existing connect-after-add behavior.
Future<ServerEditResult?> showAddServerFlow(
  BuildContext context, {
  bool connectOnSave = true,
  PairingScanLauncher scanLauncher = showRzvScanScreen,
  bool? scanSupported,
}) async {
  final canScan = scanSupported ?? rzvScanSupported;
  final method = await showAdaptiveModal<_AddServerMethod>(
    context,
    builder: (_) => AdaptiveModal(
      title: 'Add Server',
      content: MotifSection(
        dividerIndent: MotifSpacing.lg,
        children: [
          MotifSectionRow(
            key: const ValueKey('add-server-scan'),
            leading: const Icon(Icons.qr_code_scanner),
            title: 'Scan QR Code',
            subtitle: canScan
                ? 'Use the camera to scan a motif pairing code.'
                : 'Camera scanning is unavailable on this platform.',
            trailing: const Icon(Icons.chevron_right),
            onTap: canScan
                ? () => Navigator.of(context).pop(_AddServerMethod.scan)
                : null,
          ),
          MotifSectionRow(
            key: const ValueKey('add-server-manual'),
            leading: const Icon(Icons.keyboard_outlined),
            title: 'Enter Manually',
            subtitle: 'Configure SSH, Tailscale, or a Relay pairing link.',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pop(_AddServerMethod.manual),
          ),
        ],
      ),
    ),
  );
  if (method == null || !context.mounted) return null;

  if (method == _AddServerMethod.manual) {
    return showServerEditSheet(context, connectOnSave: connectOnSave);
  }

  final scanResult = await scanLauncher(context);
  if (scanResult == null || !context.mounted) return null;
  if (scanResult is RzvScanManualEntry) {
    return showServerEditSheet(
      context,
      initialKind: ServerKind.rendezvous,
      connectOnSave: connectOnSave,
    );
  }
  final link = (scanResult as RzvScannedLink).link;
  try {
    final app = readObservationScope<AppState>(context);
    final id = await app.addServerFromPairingUri(link);
    final server = app.serverById(id);
    if (server == null) return null;
    return ServerEditResult(server: server, connectAfterSave: connectOnSave);
  } on FormatException catch (error) {
    if (context.mounted) {
      showMotifToast(context, 'Invalid pairing code: ${error.message}');
    }
    return null;
  } catch (error) {
    if (context.mounted) {
      showMotifToast(context, 'Could not add server: $error');
    }
    return null;
  }
}
