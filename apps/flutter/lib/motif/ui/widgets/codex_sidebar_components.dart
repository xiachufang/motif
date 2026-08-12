import 'package:flutter/material.dart';

import '../theme/motif_theme.dart';

class CodexSidebarHeader extends StatelessWidget {
  const CodexSidebarHeader({
    required this.actions,
    required this.label,
    super.key,
  });

  final List<Widget> actions;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      child: Row(
        children: [
          Text(label, style: MotifType.caption),
          const Spacer(),
          for (var index = 0; index < actions.length; index++) ...[
            if (index > 0) const SizedBox(width: MotifSpacing.xs),
            actions[index],
          ],
        ],
      ),
    );
  }
}

class CodexSidebarIconButton extends StatelessWidget {
  const CodexSidebarIconButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    this.busy = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? c.accentFill() : Colors.transparent,
        borderRadius: BorderRadius.circular(MotifRadius.xs),
        child: InkWell(
          borderRadius: BorderRadius.circular(MotifRadius.xs),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(MotifSpacing.sm),
            child: busy
                ? SizedBox.square(
                    dimension: MotifIconSize.md,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.accent,
                    ),
                  )
                : Icon(
                    icon,
                    size: MotifIconSize.md,
                    color: selected ? c.accent : c.textTertiary,
                  ),
          ),
        ),
      ),
    );
  }
}

class CodexSidebarSectionHeading extends StatelessWidget {
  const CodexSidebarSectionHeading(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MotifSpacing.lg,
        MotifSpacing.lg,
        MotifSpacing.lg,
        MotifSpacing.xs,
      ),
      child: Text(
        label,
        style: MotifType.headline.copyWith(color: c.textTertiary),
      ),
    );
  }
}

class CodexSidebarThreadRow extends StatelessWidget {
  const CodexSidebarThreadRow({
    required this.title,
    required this.selected,
    required this.onTap,
    this.loading = false,
    this.active = false,
    this.pinned = false,
    this.indented = false,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final String title;
  final bool selected;
  final bool loading;
  final bool active;
  final bool pinned;
  final bool indented;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: EdgeInsets.only(
        left: indented ? MotifSpacing.xl : MotifSpacing.sm,
        right: MotifSpacing.sm,
      ),
      child: Material(
        color: selected ? c.accentFill() : Colors.transparent,
        borderRadius: BorderRadius.circular(MotifRadius.xs),
        child: InkWell(
          borderRadius: BorderRadius.circular(MotifRadius.xs),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MotifSpacing.md,
              vertical: MotifSpacing.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: MotifType.body.copyWith(color: c.textPrimary),
                      ),
                      if (subtitle?.isNotEmpty == true) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MotifType.subhead.copyWith(
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (pinned) ...[
                  const SizedBox(width: MotifSpacing.xs),
                  Icon(
                    Icons.push_pin_outlined,
                    size: MotifIconSize.sm,
                    color: c.textTertiary,
                  ),
                ],
                if (loading || active) ...[
                  const SizedBox(width: MotifSpacing.sm),
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.accent,
                    ),
                  ),
                ],
                if (trailing != null) ...[
                  const SizedBox(width: MotifSpacing.sm),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
