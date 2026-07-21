import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../net/rzv/pairing_payload.dart';
import '../../state/app/app_state.dart';
import '../../state/app/motif_scope.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import 'rzv_scan_screen.dart';

part 'rzv_pairing_sheet.g.dart';

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
    builder: (_) =>
        const _RzvPairingSheet(key: ValueKey('rendezvous-pairing-sheet')),
  );
}

@ObservableModel()
class _RzvPairingViewModel extends _$_RzvPairingViewModel {
  _RzvPairingViewModel({
    MotifPairingPayload? parsed,
    String? error,
    bool busy = false,
  }) : super(parsed, error, busy);
}

@ObservationWidget()
class _RzvPairingSheet extends _$_RzvPairingSheet {
  const _RzvPairingSheet({super.key});

  @PlainState(name: 'controller')
  TextEditingController createController() => TextEditingController();

  @ObservableState(name: 'viewModel')
  _RzvPairingViewModel createViewModel() => _RzvPairingViewModel();

  void _onChanged(_RzvPairingViewModel viewModel, String value) {
    final text = value.trim();
    observationTransaction(() {
      if (text.isEmpty) {
        viewModel
          ..parsed = null
          ..error = null;
        return;
      }
      try {
        viewModel
          ..parsed = MotifPairingPayload.parse(text)
          ..error = null;
      } on FormatException catch (e) {
        viewModel
          ..parsed = null
          ..error = e.message;
      }
    });
  }

  Future<void> _scan(
    BuildContext context,
    TextEditingController controller,
    _RzvPairingViewModel viewModel,
  ) async {
    final link = await showRzvScanScreen(context);
    if (link == null || !context.mounted) return;
    controller.text = link;
    _onChanged(viewModel, link);
  }

  Future<void> _pair(
    BuildContext context,
    TextEditingController controller,
    _RzvPairingViewModel viewModel,
  ) async {
    if (viewModel.parsed == null || viewModel.busy) return;
    viewModel.busy = true;
    try {
      final id = await readObservationScope<AppState>(
        context,
      ).addServerFromPairingUri(controller.text.trim());
      if (context.mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (context.mounted) {
        observationTransaction(() {
          viewModel
            ..error = '$e'
            ..busy = false;
        });
      }
    }
  }

  @override
  Widget build(
    BuildContext context, {
    required TextEditingController controller,
    required _RzvPairingViewModel viewModel,
  }) {
    final c = context.motif;
    final payload = viewModel.parsed;
    return AdaptiveModal(
      title: 'Pair with a server',
      actions: [
        TextButton(
          onPressed: payload != null && !viewModel.busy
              ? () => _pair(context, controller, viewModel)
              : null,
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
            style: MotifType.subhead.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: MotifSpacing.md),
          if (_scanSupported) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: viewModel.busy
                    ? null
                    : () => _scan(context, controller, viewModel),
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('Scan QR'),
              ),
            ),
            const SizedBox(height: MotifSpacing.md),
          ],
          TextField(
            controller: controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.url,
            onChanged: (value) => _onChanged(viewModel, value),
            decoration: InputDecoration(
              hintText: 'motif://pair?v=1&rzv=…',
              border: const OutlineInputBorder(),
              errorText: viewModel.error,
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
        borderRadius: BorderRadius.circular(MotifRadius.xs),
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
                style: MotifType.caption.copyWith(
                  color: c.textSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w600),
          ),
          Text(
            reach,
            style: MotifType.caption.copyWith(
              color: c.textTertiary,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
