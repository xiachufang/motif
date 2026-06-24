import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../net/rzv/pairing_payload.dart';
import '../../state/app_state.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import 'rzv_scan_screen.dart';

/// Whether camera QR scanning is available on this platform. mobile_scanner
/// supports iOS / Android / macOS / web; desktop Linux/Windows fall back to
/// pasting the link.
bool get _scanSupported {
  if (kIsWeb) return true;
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.android:
    case TargetPlatform.macOS:
      return true;
    default:
      return false;
  }
}

/// Add a rendezvous server by pasting the `motif://pair?...` link that
/// `motifd --rzv-relay` prints (as a QR + a link). Returns the new server's id
/// on success, or null if cancelled. Camera QR scanning can later feed the same
/// [AppState.addServerFromPairingUri] funnel.
Future<String?> showRzvPairingSheet(BuildContext context) {
  return showAdaptiveModal<String>(
    context,
    builder: (_) => const _RzvPairingSheet(),
  );
}

class _RzvPairingSheet extends StatefulWidget {
  const _RzvPairingSheet();

  @override
  State<_RzvPairingSheet> createState() => _RzvPairingSheetState();
}

class _RzvPairingSheetState extends State<_RzvPairingSheet> {
  final _controller = TextEditingController();
  MotifPairingPayload? _parsed;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final text = value.trim();
    setState(() {
      if (text.isEmpty) {
        _parsed = null;
        _error = null;
        return;
      }
      try {
        _parsed = MotifPairingPayload.parse(text);
        _error = null;
      } on FormatException catch (e) {
        _parsed = null;
        _error = e.message;
      }
    });
  }

  Future<void> _scan() async {
    final link = await showRzvScanScreen(context);
    if (link == null || !mounted) return;
    _controller.text = link;
    _onChanged(link);
  }

  Future<void> _pair() async {
    if (_parsed == null || _busy) return;
    setState(() => _busy = true);
    try {
      final id = await context.read<AppState>().addServerFromPairingUri(
        _controller.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final payload = _parsed;
    return AdaptiveModal(
      title: 'Pair with a server',
      actions: [
        TextButton(
          onPressed: payload != null && !_busy ? _pair : null,
          child: const Text('Pair'),
        ),
      ],
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'On the server, run motifd with --rzv-relay; it prints a '
            'motif://pair link (and a QR). Scan the QR or paste the link here.',
            style: TextStyle(color: c.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: MotifSpacing.md),
          if (_scanSupported) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('Scan QR'),
              ),
            ),
            const SizedBox(height: MotifSpacing.md),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.url,
            onChanged: _onChanged,
            decoration: InputDecoration(
              hintText: 'motif://pair?v=1&rzv=…',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
          ),
          if (payload != null) ...[
            const SizedBox(height: MotifSpacing.md),
            _Preview(payload: payload),
          ],
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.payload});

  final MotifPairingPayload payload;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final pinned = payload.pubKey != null;
    final reach = payload.isRendezvous
        ? 'relay ${payload.relay}'
        : 'direct ${payload.hosts.join(", ")}:${payload.port}';
    final title = payload.name?.isNotEmpty == true
        ? payload.name!
        : (payload.isRendezvous ? payload.relay! : payload.hosts.first);
    return Container(
      padding: const EdgeInsets.all(MotifSpacing.md),
      decoration: BoxDecoration(
        color: c.subtleFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                pinned ? Icons.lock : Icons.lock_open,
                size: 14,
                color: pinned ? c.success : c.warning,
              ),
              const SizedBox(width: 6),
              Text(
                pinned ? 'End-to-end encrypted (cert pinned)' : 'Plaintext',
                style: TextStyle(color: c.textSecondary, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w600),
          ),
          Text(reach, style: TextStyle(color: c.textTertiary, fontSize: 12)),
        ],
      ),
    );
  }
}
