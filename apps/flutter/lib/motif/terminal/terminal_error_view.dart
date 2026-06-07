import 'package:flutter/material.dart';

import '../ui/theme/motif_theme.dart';

class TerminalErrorView extends StatelessWidget {
  final String title;
  final String message;
  final String? details;
  final VoidCallback? onRetry;

  const TerminalErrorView({
    super.key,
    required this.title,
    required this.message,
    this.details,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: c.background,
      padding: const EdgeInsets.all(MotifSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: c.danger),
              const SizedBox(width: MotifSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: MotifSpacing.md),
          Text(message, style: TextStyle(color: c.textSecondary)),
          if (onRetry != null) ...[
            const SizedBox(height: MotifSpacing.md),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh, size: 16, color: c.textPrimary),
              label: Text(
                'Retry now',
                style: TextStyle(color: c.textPrimary),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: c.border),
              ),
            ),
          ],
          if (details != null && details!.isNotEmpty) ...[
            const SizedBox(height: MotifSpacing.md),
            SelectableText(
              details!,
              style: TextStyle(
                color: c.textTertiary,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
