import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/desktop_launch.dart';
import '../../update/desktop_update_service.dart';
import '../theme/motif_theme.dart';
import 'adaptive_modal.dart';

/// Presents the low-risk update flow: users are sent to the official GitHub
/// Release page and install the new version themselves.
Future<void> showDesktopUpdateDialog(
  BuildContext context,
  DesktopUpdate update, {
  Future<void> Function()? onSkipVersion,
}) {
  return showAdaptiveModal<void>(
    context,
    builder: (dialogContext) => AdaptiveModal(
      title: 'Update available',
      showCloseButton: false,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            child: Container(
              width: MotifControlSize.xl,
              height: MotifControlSize.xl,
              decoration: BoxDecoration(
                color: dialogContext.motif.accentFill(),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.system_update_alt_rounded,
                size: MotifIconSize.lg,
                color: dialogContext.motif.accent,
              ),
            ),
          ),
          const SizedBox(height: MotifSpacing.lg),
          Text(
            'Motif ${update.version} is ready',
            textAlign: TextAlign.center,
            style: MotifType.headline.copyWith(
              color: dialogContext.motif.textPrimary,
            ),
          ),
          const SizedBox(height: MotifSpacing.xs),
          Text(
            'Download it from the release page, then install it when you\'re ready.',
            textAlign: TextAlign.center,
            style: MotifType.subhead.copyWith(
              color: dialogContext.motif.textSecondary,
            ),
          ),
          const SizedBox(height: MotifSpacing.xl),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              unawaited(openExternalUrl(update.releaseUrl.toString()));
            },
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Download update'),
          ),
          const SizedBox(height: MotifSpacing.sm),
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Remind me later'),
          ),
          if (onSkipVersion != null) ...[
            const SizedBox(height: MotifSpacing.xs),
            TextButton(
              onPressed: () async {
                await onSkipVersion();
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              style: TextButton.styleFrom(
                foregroundColor: dialogContext.motif.textTertiary,
              ),
              child: const Text('Skip this version'),
            ),
          ],
        ],
      ),
    ),
  );
}
