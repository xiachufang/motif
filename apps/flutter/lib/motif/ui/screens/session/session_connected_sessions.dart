part of '../session_screen.dart';

class _ConnectedSessionsPanel extends StatelessWidget {
  final AppState app;
  final String currentServerId;
  final String currentSession;
  final Future<void> Function(String serverId, String session)
  onSessionSelected;

  const _ConnectedSessionsPanel({
    required this.app,
    required this.currentServerId,
    required this.currentSession,
    required this.onSessionSelected,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final groups = app.connectedServers;
    return Column(
      children: [
        const _SidebarPanelHeader(
          icon: Icons.list_alt_outlined,
          title: 'Sessions',
        ),
        Expanded(
          child: ListView(
            key: const ValueKey('sidebar-session-list'),
            padding: const EdgeInsets.fromLTRB(
              MotifSpacing.md,
              MotifSpacing.sm,
              MotifSpacing.md,
              MotifSpacing.xl,
            ),
            children: [
              if (groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(MotifSpacing.sm),
                  child: Text(
                    'No connected servers',
                    style: MotifType.subhead.copyWith(color: c.textSecondary),
                  ),
                )
              else
                for (final group in groups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      4,
                      MotifSpacing.sm,
                      4,
                      MotifSpacing.xs,
                    ),
                    child: Text(
                      group.profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MotifType.caption.copyWith(
                        color: c.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final session in _sessionsForServer(
                    group.profile,
                    group.sessions.sessions,
                    currentServerId: currentServerId,
                    currentSession: currentSession,
                  ))
                    _SidebarSessionRow(
                      serverId: group.profile.id,
                      session: session,
                      selected:
                          group.profile.id == currentServerId &&
                          session.name == currentSession,
                      enabled: group.access.isReady,
                      onTap: () =>
                          onSessionSelected(group.profile.id, session.name),
                    ),
                  if (_sessionsForServer(
                    group.profile,
                    group.sessions.sessions,
                    currentServerId: currentServerId,
                    currentSession: currentSession,
                  ).isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MotifSpacing.sm,
                        vertical: MotifSpacing.xs,
                      ),
                      child: Text(
                        'No sessions',
                        style: MotifType.caption.copyWith(
                          color: c.textTertiary,
                        ),
                      ),
                    ),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SidebarPanelHeader extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SidebarPanelHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: MotifSpacing.md),
      decoration: BoxDecoration(
        color: c.background,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c.textSecondary),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MotifType.body.copyWith(
                color: c.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarSessionRow extends StatelessWidget {
  final String serverId;
  final SessionInfo session;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _SidebarSessionRow({
    required this.serverId,
    required this.session,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final bg = selected ? c.accentFill(0.14) : Colors.transparent;
    final fg = selected ? c.accent : c.textPrimary;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(MotifRadius.sm),
      child: InkWell(
        key: ValueKey('sidebar-session-$serverId-${session.name}'),
        borderRadius: BorderRadius.circular(MotifRadius.sm),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MotifSpacing.sm,
            vertical: 7,
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.check : Icons.terminal,
                size: 16,
                color: selected ? c.accent : c.textSecondary,
              ),
              const SizedBox(width: MotifSpacing.sm),
              Expanded(
                child: Text(
                  session.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.subhead.copyWith(
                    color: enabled ? fg : c.textTertiary,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarResizeHandle extends StatelessWidget {
  static const double extent = 8;

  final Axis axis;
  final ValueChanged<double> onDragDelta;

  const _SidebarResizeHandle({
    super.key,
    required this.axis,
    required this.onDragDelta,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final horizontal = axis == Axis.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: horizontal
            ? (details) => onDragDelta(details.delta.dx)
            : null,
        onVerticalDragUpdate: horizontal
            ? null
            : (details) => onDragDelta(details.delta.dy),
        child: Container(
          width: horizontal ? extent : double.infinity,
          height: horizontal ? double.infinity : extent,
          alignment: Alignment.center,
          child: Container(
            width: horizontal ? 1 : double.infinity,
            height: horizontal ? double.infinity : 1,
            color: c.border,
          ),
        ),
      ),
    );
  }
}
