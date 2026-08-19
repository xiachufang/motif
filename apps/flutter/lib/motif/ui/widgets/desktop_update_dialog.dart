import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../log/log.dart';
import '../../platform/desktop_launch.dart';
import '../../update/desktop_update_download.dart';
import '../../update/desktop_update_service.dart';
import '../theme/motif_theme.dart';
import 'adaptive_modal.dart';

/// Downloads the verified asset for the current platform and opens it with the
/// desktop shell. The official release page remains available as a fallback.
Future<void> showDesktopUpdateDialog(
  BuildContext context,
  DesktopUpdate update, {
  Future<void> Function()? onSkipVersion,
  DesktopUpdateDownloadController? downloader,
}) {
  return showAdaptiveModal<void>(
    context,
    builder: (dialogContext) => AdaptiveModal(
      title: 'Update available',
      showCloseButton: false,
      content: _DesktopUpdateDialogContent(
        update: update,
        downloader: downloader ?? DesktopUpdateDownloader(),
        onSkipVersion: onSkipVersion,
      ),
    ),
  );
}

class _DesktopUpdateDialogContent extends StatefulWidget {
  const _DesktopUpdateDialogContent({
    required this.update,
    required this.downloader,
    this.onSkipVersion,
  });

  final DesktopUpdate update;
  final DesktopUpdateDownloadController downloader;
  final Future<void> Function()? onSkipVersion;

  @override
  State<_DesktopUpdateDialogContent> createState() =>
      _DesktopUpdateDialogContentState();
}

class _DesktopUpdateDialogContentState
    extends State<_DesktopUpdateDialogContent> {
  bool _downloading = false;
  DesktopUpdateDownloadProgress? _progress;
  String? _error;

  Future<void> _downloadAndOpen() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });
    try {
      await widget.downloader.downloadAndOpen(
        widget.update,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error, stackTrace) {
      Log.w(
        'Desktop update download failed',
        name: 'motif.update',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error =
            'Could not download and open the update. Try again or use the release page.';
      });
    }
  }

  void _openReleasePage() {
    Navigator.of(context).pop();
    unawaited(openExternalUrl(widget.update.releaseUrl.toString()));
  }

  @override
  Widget build(BuildContext context) {
    final fraction = _progress?.fraction.clamp(0.0, 1.0).toDouble();
    final percent = fraction == null ? null : (fraction * 100).round();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          child: Container(
            width: MotifControlSize.xl,
            height: MotifControlSize.xl,
            decoration: BoxDecoration(
              color: context.motif.accentFill(),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.system_update_alt_rounded,
              size: MotifIconSize.lg,
              color: context.motif.accent,
            ),
          ),
        ),
        const SizedBox(height: MotifSpacing.lg),
        Text(
          'Motif ${widget.update.version} is ready',
          textAlign: TextAlign.center,
          style: MotifType.headline.copyWith(color: context.motif.textPrimary),
        ),
        const SizedBox(height: MotifSpacing.xs),
        Text(
          'Download the verified update for this computer, then open it to install.',
          textAlign: TextAlign.center,
          style: MotifType.subhead.copyWith(color: context.motif.textSecondary),
        ),
        if (_downloading) ...[
          const SizedBox(height: MotifSpacing.lg),
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: MotifSpacing.xs),
          Text(
            percent == null ? 'Starting download…' : 'Downloading… $percent%',
            textAlign: TextAlign.center,
            style: MotifType.caption.copyWith(
              color: context.motif.textSecondary,
            ),
          ),
        ],
        if (_error case final error?) ...[
          const SizedBox(height: MotifSpacing.lg),
          Text(
            error,
            textAlign: TextAlign.center,
            style: MotifType.caption.copyWith(color: context.motif.danger),
          ),
        ],
        const SizedBox(height: MotifSpacing.xl),
        FilledButton.icon(
          onPressed: _downloading ? null : () => unawaited(_downloadAndOpen()),
          icon: _downloading
              ? const SizedBox(
                  width: MotifIconSize.sm,
                  height: MotifIconSize.sm,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.file_download_outlined),
          label: Text(_error == null ? 'Download and open' : 'Try again'),
        ),
        const SizedBox(height: MotifSpacing.sm),
        OutlinedButton(
          onPressed: _downloading ? null : _openReleasePage,
          child: const Text('Open release page'),
        ),
        const SizedBox(height: MotifSpacing.xs),
        TextButton(
          onPressed: _downloading ? null : () => Navigator.of(context).pop(),
          child: const Text('Remind me later'),
        ),
        if (widget.onSkipVersion case final skip?) ...[
          const SizedBox(height: MotifSpacing.xs),
          TextButton(
            onPressed: _downloading
                ? null
                : () async {
                    await skip();
                    if (context.mounted) Navigator.of(context).pop();
                  },
            style: TextButton.styleFrom(
              foregroundColor: context.motif.textTertiary,
            ),
            child: const Text('Skip this version'),
          ),
        ],
      ],
    );
  }
}
