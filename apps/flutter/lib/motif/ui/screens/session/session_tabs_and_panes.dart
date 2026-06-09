part of '../session_screen.dart';

class _TabBar extends StatelessWidget {
  final MotifClient motif;
  final VoidCallback onNewPty;
  final bool inTitleBar;
  const _TabBar({
    required this.motif,
    required this.onNewPty,
    this.inTitleBar = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      key: ValueKey(inTitleBar ? 'title-tab-bar' : 'body-tab-bar'),
      height: 44,
      color: inTitleBar ? Colors.transparent : c.background,
      child: Row(
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
                    scale: 1 + lift * 0.02,
                    child: Material(
                      type: MaterialType.transparency,
                      child: child,
                    ),
                  );
                },
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: MotifSpacing.sm,
                vertical: MotifSpacing.sm,
              ),
              itemCount: motif.views.length,
              onReorderItem: (oldIndex, newIndex) {
                if (oldIndex < 0 || oldIndex >= motif.views.length) return;
                final targetIndex = newIndex
                    .clamp(0, motif.views.length - 1)
                    .toInt();
                if (targetIndex == oldIndex) return;
                final viewId = motif.views[oldIndex].id;
                unawaited(
                  motif.moveView(viewId, targetIndex).catchError((Object e) {
                    if (context.mounted) {
                      showMotifToast(context, 'Move tab failed: $e');
                    }
                  }),
                );
              },
              itemBuilder: (context, i) {
                final v = motif.views[i];
                final active = v.id == motif.activeViewId;
                final (icon, label) = _describe(v, motif);
                return Padding(
                  key: ValueKey('tab-${v.id}'),
                  padding: const EdgeInsets.only(right: MotifSpacing.xs),
                  child: GestureDetector(
                    onTap: () {
                      if (motif.isLive) {
                        motif.activateView(v.id);
                      } else {
                        motif.selectViewLocally(v.id);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MotifSpacing.md,
                      ),
                      decoration: BoxDecoration(
                        color: active ? c.accentFill() : c.subtleFill,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ReorderableDragStartListener(
                            index: i,
                            child: Row(
                              children: [
                                Icon(
                                  icon,
                                  size: 14,
                                  color: active ? c.accent : c.textSecondary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  label,
                                  style: TextStyle(
                                    color: active ? c.accent : c.textSecondary,
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 4),
                          Tooltip(
                            message:
                                'Close tab (${_primaryShortcutLabel('W')})',
                            child: GestureDetector(
                              key: ValueKey('close-tab-${v.id}'),
                              behavior: HitTestBehavior.opaque,
                              onTap: () => unawaited(
                                _closeViewWithConfirmation(context, motif, v),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(3),
                                child: Icon(
                                  Icons.close,
                                  size: 13,
                                  color: active ? c.accent : c.textTertiary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Center(
            child: Tooltip(
              message: 'New terminal (${_primaryShortcutLabel('T')})',
              child: GestureDetector(
                onTap: onNewPty,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: MotifSpacing.xs,
                    right: inTitleBar ? MotifSpacing.sm : MotifSpacing.md,
                  ),
                  child: Icon(Icons.add_circle, size: 20, color: c.accent),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  (IconData, String) _describe(ViewInfo v, MotifClient motif) {
    return switch (v.spec) {
      PtyViewSpec(:final ptyId) => (
        Icons.terminal,
        motif.runningCommand[ptyId] ??
            motif.ptys
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
      DiffViewSpec() => (Icons.difference_outlined, 'diff'),
      ImageViewSpec(:final path) => (
        Icons.image_outlined,
        path.split('/').last,
      ),
      OtherViewSpec(:final typeName) => (Icons.tab, typeName),
    };
  }
}

class _PaneStack extends StatelessWidget {
  final ViewInfo? activeView;
  final bool attaching;
  final bool mountPanes;
  final List<ViewInfo> mountedViews;
  final MotifClient motif;
  final double fontSize;
  final TerminalPalette palette;
  final int focusSerial;
  final ValueListenable<double> keyboardInset;

  const _PaneStack({
    required this.activeView,
    required this.attaching,
    required this.mountPanes,
    required this.mountedViews,
    required this.motif,
    required this.fontSize,
    required this.palette,
    required this.focusSerial,
    required this.keyboardInset,
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
                enabled: view.id == active.id,
                child: _PaneForView(
                  view: view,
                  active: view.id == active.id,
                  motif: motif,
                  fontSize: fontSize,
                  palette: palette,
                  focusSerial: focusSerial,
                  keyboardInset: keyboardInset,
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
  final MotifClient motif;
  final double fontSize;
  final TerminalPalette palette;
  final int focusSerial;
  final ValueListenable<double> keyboardInset;

  const _PaneForView({
    required this.view,
    required this.active,
    required this.motif,
    required this.fontSize,
    required this.palette,
    required this.focusSerial,
    required this.keyboardInset,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return switch (view.spec) {
      PtyViewSpec(:final ptyId) =>
        (kIsWeb || kUseNativeTerminal)
            ? nativeTerminalView(
                key: ValueKey('terminal-$ptyId'),
                motif: motif,
                ptyId: ptyId,
                fontSize: fontSize,
                active: active,
                focusSerial: focusSerial,
                palette: palette,
                keyboardInset: keyboardInset,
              )
            : const TerminalErrorView(
                title: 'Native terminal disabled',
                message:
                    'MOTIF_NATIVE_TERMINAL=false disables the Ghostty terminal.',
              ),
      PreviewViewSpec(:final path) => PreviewPane(
        key: ValueKey('preview-$path'),
        path: path,
        motif: motif,
      ),
      DiffViewSpec(:final staged, :final path) => GitDiffPanel(
        key: ValueKey('diff-$staged-$path'),
        cwd: motif.activeCwd,
        initialStaged: staged,
        path: path,
        motif: motif,
      ),
      ImageViewSpec(:final path) => PreviewPane(
        key: ValueKey('image-$path'),
        path: path,
        motif: motif,
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
