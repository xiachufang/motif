import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../net/rzv/pairing_payload.dart';
import '../theme/motif_theme.dart';

part 'rzv_scan_screen.g.dart';

/// Full-screen camera scanner that pops back the first `motif://pair` link it
/// detects (the QR `motifd --rzv-relay` prints). The [MobileScanner] widget
/// manages its own camera controller lifecycle (start/stop/dispose).
/// Whether camera QR scanning is available on this platform. `mobile_scanner`
/// supports iOS / Android / macOS / web; Linux and Windows use manual entry.
bool get rzvScanSupported {
  if (kIsWeb) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS ||
    TargetPlatform.android ||
    TargetPlatform.macOS => true,
    _ => false,
  };
}

sealed class RzvScanResult {
  const RzvScanResult();
}

final class RzvScannedLink extends RzvScanResult {
  const RzvScannedLink(this.link);

  final String link;
}

final class RzvScanManualEntry extends RzvScanResult {
  const RzvScanManualEntry();
}

final class RzvScanCoordinator {
  bool handled = false;
  final Observable<String?> error = Observable(null);
}

@ObservationWidget()
class RzvScanScreen extends _$RzvScanScreen {
  const RzvScanScreen({super.key});

  @PlainState(name: 'coordinator')
  RzvScanCoordinator createCoordinator() => RzvScanCoordinator();

  void _onDetect(
    BuildContext context,
    RzvScanCoordinator coordinator,
    BarcodeCapture capture,
  ) {
    if (coordinator.handled) return;
    String? validationError;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      try {
        MotifPairingPayload.parse(raw);
        coordinator.handled = true;
        Navigator.of(context).pop(RzvScannedLink(raw));
        return;
      } on FormatException catch (error) {
        validationError = error.message;
      }
    }
    if (validationError != null && coordinator.error.value != validationError) {
      coordinator.error.value = validationError;
    }
  }

  @override
  Widget build(
    BuildContext context, {
    required RzvScanCoordinator coordinator,
  }) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan pairing QR'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: (capture) => _onDetect(context, coordinator, capture),
            errorBuilder: (context, error) => _CameraError(error: error),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 48,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(MotifRadius.xs),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Point at the motif://pair QR printed by motifd',
                      style: MotifType.subhead.copyWith(color: Colors.white),
                    ),
                    if (coordinator.error.value case final error?) ...[
                      const SizedBox(height: 4),
                      Text(
                        error,
                        key: const ValueKey('pairing-scan-error'),
                        textAlign: TextAlign.center,
                        style: MotifType.caption.copyWith(
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                    TextButton(
                      onPressed: () =>
                          Navigator.of(context).pop(const RzvScanManualEntry()),
                      child: const Text('Enter Manually'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'Camera permission was denied.',
      MobileScannerErrorCode.unsupported =>
        'Camera scanning is unavailable on this device.',
      _ => 'Could not start the camera.',
    };
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(MotifSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, color: Colors.white),
              const SizedBox(height: MotifSpacing.md),
              Text(
                message,
                textAlign: TextAlign.center,
                style: MotifType.body.copyWith(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Push the scanner and return a validated link or a request to continue with
/// manual entry. Returns null when the user backs out.
Future<RzvScanResult?> showRzvScanScreen(BuildContext context) {
  return Navigator.of(context).push<RzvScanResult>(
    MaterialPageRoute(
      builder: (_) => const RzvScanScreen(),
      fullscreenDialog: true,
    ),
  );
}
