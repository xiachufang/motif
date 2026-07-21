import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/motif_theme.dart';

part 'rzv_scan_screen.g.dart';

/// Full-screen camera scanner that pops back the first `motif://pair` link it
/// detects (the QR `motifd --rzv-relay` prints). The [MobileScanner] widget
/// manages its own camera controller lifecycle (start/stop/dispose).
final class RzvScanCoordinator {
  bool handled = false;
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
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw != null && raw.startsWith('motif://pair')) {
        coordinator.handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
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
                child: Text(
                  'Point at the motif://pair QR printed by motifd',
                  style: MotifType.subhead.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Push the scanner and return the scanned `motif://pair` link, or null if the
/// user backed out.
Future<String?> showRzvScanScreen(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => const RzvScanScreen(),
      fullscreenDialog: true,
    ),
  );
}
