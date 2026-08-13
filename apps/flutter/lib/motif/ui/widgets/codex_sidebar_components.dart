import 'package:material_ui/material_ui.dart';

import '../theme/motif_theme.dart';
import 'codex_motion.dart';

const double codexSidebarRowHeight = MotifControlSize.sm;

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
            child: CodexMotionSwitcher(
              animateSize: true,
              offset: Offset.zero,
              child: busy
                  ? SizedBox.square(
                      key: const ValueKey('busy'),
                      dimension: MotifIconSize.md,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.accent,
                      ),
                    )
                  : Icon(
                      key: const ValueKey('icon'),
                      icon,
                      size: MotifIconSize.md,
                      color: selected ? c.accent : c.textTertiary,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class CodexSidebarSectionHeading extends StatelessWidget {
  const CodexSidebarSectionHeading(this.label, {this.trailing, super.key});

  final String label;
  final Widget? trailing;

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
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: MotifType.headline.copyWith(color: c.textTertiary),
            ),
          ),
          ?trailing,
        ],
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
    this.subtitleIcon,
    this.subtitleSpacing = 0,
    this.trailing,
    this.height = codexSidebarRowHeight,
    this.horizontalContentPadding = MotifSpacing.md,
    super.key,
  });

  final String title;
  final bool selected;
  final bool loading;
  final bool active;
  final bool pinned;
  final bool indented;
  final String? subtitle;
  final IconData? subtitleIcon;
  final double subtitleSpacing;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double height;
  final double horizontalContentPadding;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: EdgeInsets.only(
        left: indented ? MotifSpacing.xl : MotifSpacing.sm,
        right: MotifSpacing.sm,
      ),
      child: SizedBox(
        height: height,
        child: Material(
          color: selected ? c.accentFill() : Colors.transparent,
          borderRadius: BorderRadius.circular(MotifRadius.xs),
          child: InkWell(
            borderRadius: BorderRadius.circular(MotifRadius.xs),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalContentPadding,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MotifType.sidebar.copyWith(
                            color: c.textPrimary,
                          ),
                        ),
                        if (subtitle?.isNotEmpty == true) ...[
                          SizedBox(height: subtitleSpacing),
                          Row(
                            children: [
                              if (subtitleIcon != null) ...[
                                Icon(
                                  subtitleIcon,
                                  size: MotifIconSize.sm,
                                  color: c.textTertiary,
                                ),
                                const SizedBox(width: MotifSpacing.xs),
                              ],
                              Expanded(
                                child: Text(
                                  subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: MotifType.caption.copyWith(
                                    color: c.textTertiary,
                                    height: 1,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                            ],
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
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: MotifSpacing.sm + 14,
                    ),
                    child: CodexMotionSwitcher(
                      animateSize: true,
                      offset: Offset.zero,
                      child: loading || active
                          ? Row(
                              key: const ValueKey('active'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
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
                            )
                          : const SizedBox.shrink(key: ValueKey('inactive')),
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: MotifSpacing.sm),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
