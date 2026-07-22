part of '../session_screen.dart';

class _TabBar extends StatelessWidget {
  final WorkspaceViewModel workspaceState;
  final TerminalController terminal;
  final ViewController views;
  final VoidCallback onNewPty;
  final bool inTitleBar;
  const _TabBar({
    required this.workspaceState,
    required this.terminal,
    required this.views,
    required this.onNewPty,
    this.inTitleBar = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final items = workspaceState.views.items;
    return Container(
      key: ValueKey(inTitleBar ? 'title-tab-bar' : 'body-tab-bar'),
      height: 44,
      color: inTitleBar ? Colors.transparent : c.background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              proxyDecorator: (child, index, animation) => AnimatedBuilder(
                animation: animation,
                child: child,
                builder: (context, child) {
                  final lift = Curves.easeOut.transform(animation.value);
                  return Transform.scale(
                    scale: 1 + lift * 0.04,
                    child: Material(
                      key: const ValueKey('tab-drag-feedback'),
                      color: c.surfaceElevated,
                      elevation: 8 * lift,
                      shadowColor: c.shadow,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(MotifRadius.pill),
                        side: BorderSide(
                          color: c.accent.withValues(alpha: 0.75 * lift),
                          width: 1.5,
                        ),
                      ),
                      child: child,
                    ),
                  );
                },
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: MotifSpacing.sm,
                vertical: MotifSpacing.sm,
              ),
              itemCount: items.length,
              onReorderItem: (oldIndex, newIndex) {
                if (oldIndex < 0 || oldIndex >= items.length) return;
                final targetIndex = newIndex.clamp(0, items.length - 1).toInt();
                if (targetIndex == oldIndex) return;
                final viewId = items[oldIndex].id;
                unawaited(
                  views.move(viewId, targetIndex).catchError((Object e) {
                    if (context.mounted) {
                      showMotifToast(context, 'Move tab failed: $e');
                    }
                  }),
                );
              },
              itemBuilder: (context, i) {
                final v = items[i];
                final active = v.id == workspaceState.views.activeViewId;
                final (icon, label) = _describe(v);
                return Padding(
                  key: ValueKey('tab-${v.id}'),
                  padding: const EdgeInsets.only(right: MotifSpacing.xs),
                  child: _SessionTabChip(
                    active: active,
                    icon: icon,
                    label: label,
                    dragIndex: i,
                    onTap: () {
                      if (workspaceState.connection.transportAvailable) {
                        views.activate(v.id);
                      } else {
                        views.selectLocally(v.id);
                      }
                    },
                    onClose: () => unawaited(
                      _closeViewWithConfirmation(
                        context,
                        terminal: terminal,
                        views: views,
                        view: v,
                      ),
                    ),
                    closeKey: ValueKey('close-tab-${v.id}'),
                  ),
                );
              },
            ),
          ),
          IconButton(
            key: const ValueKey('new-terminal-button'),
            tooltip: 'New terminal (${_primaryShortcutLabel('T')})',
            onPressed: onNewPty,
            icon: Icon(Icons.add_circle, size: 20, color: c.accent),
          ),
        ],
      ),
    );
  }

  (IconData, String) _describe(ViewInfo v) {
    return switch (v.spec) {
      PtyViewSpec(:final ptyId) => (
        Icons.terminal,
        terminal.viewModel.runningCommand[ptyId] ??
            terminal.viewModel.ptys
                .firstWhere(
                  (p) => p.id == ptyId,
                  orElse: () => PtyInfo(id: ptyId, cols: 0, rows: 0),
                )
                .cwd
                ?.split('/')
                .last ??
            'shell',
      ),
      PreviewViewSpec(:final path) => (
        Icons.description_outlined,
        path.split('/').last,
      ),
      DiffViewSpec(:final path) => (
        Icons.difference_outlined,
        path?.split('/').last ?? 'diff',
      ),
      ImageViewSpec(:final path) => (
        Icons.image_outlined,
        path.split('/').last,
      ),
      OtherViewSpec(:final typeName) => (Icons.tab, typeName),
    };
  }
}

class _SessionTabChip extends StatelessWidget {
  final bool active;
  final IconData icon;
  final String label;
  final int dragIndex;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final Key closeKey;

  const _SessionTabChip({
    required this.active,
    required this.icon,
    required this.label,
    required this.dragIndex,
    required this.onTap,
    required this.onClose,
    required this.closeKey,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final bg = active ? c.accentFill() : c.subtleFill;
    final dragContent = Row(
      children: [
        Icon(icon, size: 14, color: active ? c.accent : c.textSecondary),
        const SizedBox(width: 6),
        Text(
          label,
          style: MotifType.monoSmall.copyWith(
            color: active ? c.accent : c.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
    final dragHandle = switch (Theme.of(context).platform) {
      TargetPlatform.android ||
      TargetPlatform.iOS => ReorderableDelayedDragStartListener(
        index: dragIndex,
        child: dragContent,
      ),
      _ => ReorderableDragStartListener(index: dragIndex, child: dragContent),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MouseRegion(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.md),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(MotifRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              dragHandle,
              const SizedBox(width: 4),
              // No Tooltip here: this chip is a ReorderableListView item, and a
              // Tooltip's OverlayPortal reactivates during reorder (the list
              // rebuilds inside its own layout callback), which mutates the
              // overlay's RenderLayoutBuilder mid-layout and throws. The sibling
              // "New terminal" button keeps its tooltip because it sits outside
              // the reorderable list.
              GestureDetector(
                key: closeKey,
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    Icons.close,
                    size: 13,
                    color: active ? c.accent : c.textTertiary,
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

class _PaneStack extends StatelessWidget {
  final ViewInfo? activeView;
  final bool attaching;
  final bool mountPanes;
  final bool workspaceActive;
  final List<ViewInfo> mountedViews;
  final TerminalController terminal;
  final WorkspaceApi workspace;
  final double fontSize;
  final TerminalPalette palette;
  final int focusSerial;
  final ValueListenable<double> keyboardInset;
  final Future<void> Function(TerminalFileTarget target) onOpenTerminalFile;

  const _PaneStack({
    required this.activeView,
    required this.attaching,
    required this.mountPanes,
    required this.workspaceActive,
    required this.mountedViews,
    required this.terminal,
    required this.workspace,
    required this.fontSize,
    required this.palette,
    required this.focusSerial,
    required this.keyboardInset,
    required this.onOpenTerminalFile,
  });

  @override
  Widget build(BuildContext context) {
    final active = activeView;
    if (active == null) {
      // While the in-screen attach is still in flight the connecting overlay
      // explains the empty pane; "No terminal yet" would be misleading.
      if (attaching) {
        return ColoredBox(color: palette.background);
      }
      final c = context.motif;
      return Center(
        child: Text(
          'No terminal yet',
          style: TextStyle(color: c.textSecondary),
        ),
      );
    }
    if (!mountPanes) {
      return ColoredBox(color: palette.background);
    }
    return Stack(
      children: [
        for (final view in mountedViews)
          // Key MUST live on the Stack's direct child so panes are matched by
          // identity across reorders/insertions. A deeper key (e.g. on a nested
          // KeyedSubtree) leaves the Stack matching positionally, so inserting a
          // tab anywhere but the end shifts every slot and tears down + rebuilds
          // every pane — destroying its live terminal grid (blank-tab bug).
          Positioned.fill(
            key: ValueKey('pane-${view.id}'),
            child: Offstage(
              offstage: view.id != active.id,
              child: TickerMode(
                enabled: workspaceActive && view.id == active.id,
                child: _PaneForView(
                  view: view,
                  active: workspaceActive && view.id == active.id,
                  terminal: terminal,
                  workspace: workspace,
                  fontSize: fontSize,
                  palette: palette,
                  focusSerial: focusSerial,
                  keyboardInset: keyboardInset,
                  onOpenTerminalFile: onOpenTerminalFile,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PaneForView extends StatelessWidget {
  final ViewInfo view;
  final bool active;
  final TerminalController terminal;
  final WorkspaceApi workspace;
  final double fontSize;
  final TerminalPalette palette;
  final int focusSerial;
  final ValueListenable<double> keyboardInset;
  final Future<void> Function(TerminalFileTarget target) onOpenTerminalFile;

  const _PaneForView({
    required this.view,
    required this.active,
    required this.terminal,
    required this.workspace,
    required this.fontSize,
    required this.palette,
    required this.focusSerial,
    required this.keyboardInset,
    required this.onOpenTerminalFile,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return switch (view.spec) {
      PtyViewSpec(:final ptyId) =>
        (kIsWeb || kUseNativeTerminal)
            ? nativeTerminalView(
                key: ValueKey('terminal-$ptyId'),
                motif: terminal,
                ptyId: ptyId,
                fontSize: fontSize,
                active: active,
                focusSerial: focusSerial,
                palette: palette,
                keyboardInset: keyboardInset,
                onOpenFile: onOpenTerminalFile,
              )
            : const TerminalErrorView(
                title: 'Native terminal disabled',
                message:
                    'MOTIF_NATIVE_TERMINAL=false disables the Ghostty terminal.',
              ),
      PreviewViewSpec(:final path) => PreviewPane(
        key: ValueKey('preview-$path'),
        path: path,
        workspace: workspace,
      ),
      DiffViewSpec(:final staged, :final path) => GitDiffView(
        key: ValueKey('diff-$staged-$path'),
        cwd: workspace.activeCwd(),
        initialStaged: staged,
        path: path,
        workspace: workspace,
        embedded: true,
      ),
      ImageViewSpec(:final path) => PreviewPane(
        key: ValueKey('image-$path'),
        path: path,
        workspace: workspace,
      ),
      OtherViewSpec(:final typeName) => Center(
        child: Text(
          'Unsupported view kind: $typeName',
          style: TextStyle(color: c.textSecondary),
        ),
      ),
    };
  }
}
