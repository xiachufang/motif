part of '../session_screen.dart';

class _SessionSidebar extends StatelessWidget {
  static const double _splitHandleExtent = 8;
  static const double _minPanelExtent = 160;

  final AppState app;
  final bool showSessions;
  final bool showFileTree;
  final bool showDiff;
  final String currentServerId;
  final String currentSession;
  final String root;
  final String? cwd;
  final WorkspaceApi workspace;
  final Future<void> Function(String serverId, String session)
  onSessionSelected;
  final ValueChanged<String> onOpenPreview;
  final OpenDiffView onOpenDiff;
  final double splitFraction;
  final ValueChanged<double> onSplitChanged;
  final double firstSplitFraction;
  final ValueChanged<double> onFirstSplitChanged;
  final double secondSplitFraction;
  final ValueChanged<double> onSecondSplitChanged;

  const _SessionSidebar({
    required this.app,
    required this.showSessions,
    required this.showFileTree,
    required this.showDiff,
    required this.currentServerId,
    required this.currentSession,
    required this.root,
    required this.cwd,
    required this.workspace,
    required this.onSessionSelected,
    required this.onOpenPreview,
    required this.onOpenDiff,
    required this.splitFraction,
    required this.onSplitChanged,
    required this.firstSplitFraction,
    required this.onFirstSplitChanged,
    required this.secondSplitFraction,
    required this.onSecondSplitChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    Widget panel(Widget child) => Container(color: c.surface, child: child);
    final panels = <Widget>[
      if (showSessions)
        panel(
          ObservationSelect(
            selector: () => _connectedSessionsSelectKey(app),
            builder: (context, _, _) => _ConnectedSessionsPanel(
              app: app,
              currentServerId: currentServerId,
              currentSession: currentSession,
              onSessionSelected: onSessionSelected,
            ),
          ),
        ),
      if (showFileTree)
        panel(
          FileTreePanel(
            key: ValueKey('sidebar-files-$root'),
            root: root,
            onOpen: onOpenPreview,
            workspace: workspace,
            embedded: true,
          ),
        ),
      if (showDiff)
        panel(
          GitDiffPanel(
            key: ValueKey('sidebar-diff-$cwd'),
            cwd: cwd,
            workspace: workspace,
            onOpenDiff: onOpenDiff,
            embedded: true,
          ),
        ),
    ];
    if (panels.isEmpty) return const SizedBox.shrink();
    if (panels.length == 1) return panels.single;
    if (panels.length == 2) {
      return _TwoPanelSidebar(
        top: panels[0],
        bottom: panels[1],
        splitFraction: splitFraction,
        onSplitChanged: onSplitChanged,
      );
    }
    return _ThreePanelSidebar(
      top: panels[0],
      middle: panels[1],
      bottom: panels[2],
      firstSplitFraction: firstSplitFraction,
      onFirstSplitChanged: onFirstSplitChanged,
      secondSplitFraction: secondSplitFraction,
      onSecondSplitChanged: onSecondSplitChanged,
    );
  }
}

class _TwoPanelSidebar extends StatelessWidget {
  final Widget top;
  final Widget bottom;
  final double splitFraction;
  final ValueChanged<double> onSplitChanged;

  const _TwoPanelSidebar({
    required this.top,
    required this.bottom,
    required this.splitFraction,
    required this.onSplitChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(
          0.0,
          constraints.maxHeight - _SessionSidebar._splitHandleExtent,
        );
        final minPanelExtent = math.min(
          _SessionSidebar._minPanelExtent,
          available / 2,
        );
        final topHeight = (available * splitFraction)
            .clamp(minPanelExtent, available - minPanelExtent)
            .toDouble();
        return Column(
          children: [
            SizedBox(height: topHeight, child: top),
            _SidebarResizeHandle(
              key: const ValueKey('sidebar-vertical-resize-handle'),
              axis: Axis.vertical,
              onDragDelta: (delta) {
                if (available <= 0) return;
                onSplitChanged(
                  ((topHeight + delta) / available).clamp(0, 1).toDouble(),
                );
              },
            ),
            Expanded(child: bottom),
          ],
        );
      },
    );
  }
}

class _ThreePanelSidebar extends StatelessWidget {
  final Widget top;
  final Widget middle;
  final Widget bottom;
  final double firstSplitFraction;
  final ValueChanged<double> onFirstSplitChanged;
  final double secondSplitFraction;
  final ValueChanged<double> onSecondSplitChanged;

  const _ThreePanelSidebar({
    required this.top,
    required this.middle,
    required this.bottom,
    required this.firstSplitFraction,
    required this.onFirstSplitChanged,
    required this.secondSplitFraction,
    required this.onSecondSplitChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(
          0.0,
          constraints.maxHeight - _SessionSidebar._splitHandleExtent * 2,
        );
        final minPanelExtent = math.min(
          _SessionSidebar._minPanelExtent,
          available / 3,
        );
        final minFraction = available <= 0 ? 0.0 : minPanelExtent / available;
        final first = firstSplitFraction
            .clamp(minFraction, 1 - minFraction * 2)
            .toDouble();
        final second = secondSplitFraction
            .clamp(first + minFraction, 1 - minFraction)
            .toDouble();
        final topHeight = available * first;
        final middleHeight = available * (second - first);
        return Column(
          children: [
            SizedBox(height: topHeight, child: top),
            _SidebarResizeHandle(
              key: const ValueKey('sidebar-vertical-resize-handle'),
              axis: Axis.vertical,
              onDragDelta: (delta) {
                if (available <= 0) return;
                onFirstSplitChanged(
                  ((topHeight + delta) / available)
                      .clamp(minFraction, second - minFraction)
                      .toDouble(),
                );
              },
            ),
            SizedBox(height: middleHeight, child: middle),
            _SidebarResizeHandle(
              key: const ValueKey('sidebar-second-vertical-resize-handle'),
              axis: Axis.vertical,
              onDragDelta: (delta) {
                if (available <= 0) return;
                onSecondSplitChanged(
                  ((topHeight + middleHeight + delta) / available)
                      .clamp(first + minFraction, 1 - minFraction)
                      .toDouble(),
                );
              },
            ),
            Expanded(child: bottom),
          ],
        );
      },
    );
  }
}
