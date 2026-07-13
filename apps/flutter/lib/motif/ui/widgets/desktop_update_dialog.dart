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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Motif ${update.version} is ready to download.',
            style: MotifType.body.copyWith(
              color: dialogContext.motif.textPrimary,
            ),
          ),
          const SizedBox(height: MotifSpacing.sm),
          Text(
            'Open the release page to download and install the latest version.',
            style: MotifType.subhead.copyWith(
              color: dialogContext.motif.textSecondary,
            ),
          ),
          if (onSkipVersion != null) ...[
            const SizedBox(height: MotifSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  await onSkipVersion();
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
                icon: const Icon(Icons.notifications_off_outlined),
                label: const Text('Skip this version'),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            unawaited(openExternalUrl(update.releaseUrl.toString()));
          },
          child: const Text('Open download page'),
        ),
      ],
    ),
  );
}
