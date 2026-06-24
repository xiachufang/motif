import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen camera scanner that pops back the first `motif://pair` link it
/// detects (the QR `motifd --rzv-relay` prints). The [MobileScanner] widget
/// manages its own camera controller lifecycle (start/stop/dispose).
class RzvScanScreen extends StatefulWidget {
  const RzvScanScreen({super.key});

  @override
  State<RzvScanScreen> createState() => _RzvScanScreenState();
}

class _RzvScanScreenState extends State<RzvScanScreen> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw != null && raw.startsWith('motif://pair')) {
        _handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
          MobileScanner(onDetect: _onDetect),
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
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Point at the motif://pair QR printed by motifd',
                  style: TextStyle(color: Colors.white, fontSize: 13),
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
