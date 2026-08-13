import 'package:material_ui/material_ui.dart';

import '../../models/motif_proto.dart';
import '../../models/resource_documents.dart';
import '../../state/workspace/workspace_api.dart';
import '../theme/motif_theme.dart';
import '../widgets/diff_text_view.dart';
import '../widgets/motif_panel_header.dart';
import '../widgets/observation_select.dart';

typedef OpenDiffView =
    Future<void> Function({String? path, required bool staged});

/// Changed-files navigator for git diff. Re-fetches when `git.changed` bumps
/// the tick and opens concrete diff tabs through [onOpenDiff].
class GitDiffPanel extends StatefulWidget {
  final String? cwd;
  final bool initialStaged;
  final WorkspaceApi workspace;
  final bool embedded;
  final bool popOnOpen;
  final OpenDiffView onOpenDiff;

  const GitDiffPanel({
    super.key,
    this.cwd,
    this.initialStaged = false,
    required this.workspace,
    required this.onOpenDiff,
    this.embedded = false,
    this.popOnOpen = false,
  });

  @override
  State<GitDiffPanel> createState() => _GitDiffPanelState();
}

class _GitDiffPanelState extends State<GitDiffPanel> {
  late bool _staged;
  _DiffFileViewMode _viewMode = _DiffFileViewMode.list;
  final Set<String> _expandedDirs = {};
  List<DiffSummaryFile> _summary = const [];
  bool _loading = true;
  String? _error;
  int _lastTick = -1;
  bool _reloadScheduled = false;

  late final WorkspaceApi _workspace;

  @override
  void initState() {
    super.initState();
    _staged = widget.initialStaged;
    _workspace = widget.workspace;
    _load();
  }

  void _onTick() {
    if (_workspace.content.gitVersion != _lastTick) _load();
  }

  Future<void> _load() async {
    _lastTick = _workspace.content.gitVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await _workspace.gitDiffSummary(
        staged: _staged,
        cwd: widget.cwd,
      );
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _openDiff(String? path) async {
    await widget.onOpenDiff(path: path, staged: _staged);
    if (widget.popOnOpen && !widget.embedded && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => ObservationSelect<int>(
    selector: () => _workspace.content.gitVersion,
    builder: (context, version, _) {
      if (version != _lastTick && !_reloadScheduled) {
        _reloadScheduled = true;
        Future.microtask(() {
          _reloadScheduled = false;
          if (mounted) _onTick();
        });
      }
      return _buildContent(context);
    },
  );

  Widget _buildContent(BuildContext context) {
    final c = context.motif;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(
            child: Text(_error!, style: TextStyle(color: c.danger)),
          )
        : _summary.isEmpty
        ? Center(
            child: Text('No changes', style: TextStyle(color: c.textSecondary)),
          )
        : _viewMode == _DiffFileViewMode.list
        ? DiffFileSidebar(
            summary: _summary,
            onOpenFile: (path) => _openDiff(path),
          )
        : Column(
            children: [
              _SummaryBar(summary: _summary),
              Expanded(
                child: _DiffFileTree(
                  summary: _summary,
                  expandedDirs: _expandedDirs,
                  onToggleDir: _toggleDir,
                  onOpenFile: (path) => _openDiff(path),
                ),
              ),
            ],
          );
    final actions = _actions();
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(
          title: _DiffTitle(staged: _staged, onChanged: _setStaged),
          actions: actions,
        ),
        body: body,
      );
    }
    return Column(
      children: [
        _EmbeddedDiffHeader(
          staged: _staged,
          onChanged: _setStaged,
          actions: actions,
        ),
        Expanded(child: body),
      ],
    );
  }

  void _toggleDir(String path) {
    setState(() {
      if (!_expandedDirs.add(path)) _expandedDirs.remove(path);
    });
  }

  List<Widget> _actions() => [
    IconButton(
      icon: Icon(
        _viewMode == _DiffFileViewMode.list
            ? Icons.account_tree_outlined
            : Icons.format_list_bulleted,
      ),
      tooltip: _viewMode == _DiffFileViewMode.list ? 'Tree view' : 'List view',
      onPressed: () {
        setState(() {
          _viewMode = _viewMode == _DiffFileViewMode.list
              ? _DiffFileViewMode.tree
              : _DiffFileViewMode.list;
        });
      },
    ),
    IconButton(
      icon: const Icon(Icons.description_outlined),
      tooltip: 'Show diff',
      onPressed: () => _openDiff(null),
    ),
  ];

  void _setStaged(bool staged) {
    setState(() => _staged = staged);
    _load();
  }
}

enum _DiffFileViewMode { list, tree }

/// Patch viewer for a concrete diff tab. A null [path] shows the full diff.
class GitDiffView extends StatefulWidget {
  final String? cwd;
  final bool initialStaged;
  final String? path;
  final WorkspaceApi workspace;
  final bool embedded;
  final bool tabActive;

  const GitDiffView({
    super.key,
    this.cwd,
    this.initialStaged = false,
    this.path,
    required this.workspace,
    this.embedded = false,
    this.tabActive = true,
  });

  @override
  State<GitDiffView> createState() => _GitDiffViewState();
}

class _GitDiffViewState extends State<GitDiffView> {
  late bool _staged;
  String _patch = '';
  List<DiffSummaryFile> _summary = const [];
  bool _loading = true;
  String? _error;
  int _lastTick = -1;
  bool _reloadScheduled = false;

  late final WorkspaceApi _workspace;

  @override
  void initState() {
    super.initState();
    _staged = widget.initialStaged;
    _workspace = widget.workspace;
    _load();
  }

  void _onTick() {
    if (_workspace.content.gitVersion != _lastTick) _load();
  }

  Future<void> _load() async {
    _lastTick = _workspace.content.gitVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await _workspace.gitDiffSummary(
        path: widget.path,
        staged: _staged,
        cwd: widget.cwd,
      );
      final patch = await _workspace.gitDiff(
        path: widget.path,
        staged: _staged,
        cwd: widget.cwd,
      );
      if (!mounted) return;
      setState(() {
        _patch = patch;
        _summary = summary;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ObservationSelect<int>(
    selector: () => _workspace.content.gitVersion,
    builder: (context, version, _) {
      if (version != _lastTick && !_reloadScheduled) {
        _reloadScheduled = true;
        Future.microtask(() {
          _reloadScheduled = false;
          if (mounted) _onTick();
        });
      }
      return _buildContent(context);
    },
  );

  Widget _buildContent(BuildContext context) {
    final c = context.motif;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(
            child: Text(_error!, style: TextStyle(color: c.danger)),
          )
        : Column(
            children: [
              Expanded(
                child: DiffDocumentView(
                  document: DiffDocument.fromUnifiedPatch(
                    patch: _patch,
                    summary: _summary,
                    fallbackPath: widget.path,
                  ),
                  tabActive: widget.tabActive,
                ),
              ),
            ],
          );
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(
          title: _DiffTitle(staged: _staged, onChanged: _setStaged),
        ),
        body: body,
      );
    }
    return Column(
      children: [
        _EmbeddedDiffHeader(
          staged: _staged,
          onChanged: _setStaged,
          actions: const [],
        ),
        Expanded(child: body),
      ],
    );
  }

  void _setStaged(bool staged) {
    setState(() => _staged = staged);
    _load();
  }
}

/// Shared renderer for a stable diff document.
///
/// Session feeds it a document loaded from Git, while Codex feeds it the exact
/// patch snapshot emitted by app-server for one turn.
class DiffDocumentView extends StatefulWidget {
  const DiffDocumentView({
    required this.document,
    this.initialPath,
    this.onOpenFile,
    this.tabActive = true,
    super.key,
  });

  final DiffDocument document;
  final String? initialPath;
  final ValueChanged<String>? onOpenFile;
  final bool tabActive;

  @override
  State<DiffDocumentView> createState() => _DiffDocumentViewState();
}

class _DiffDocumentViewState extends State<DiffDocumentView> {
  final Set<String> _collapsedPaths = {};
  final Map<String, GlobalKey> _sectionKeys = {};

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final files = widget.document.files;
    if (files.isEmpty) {
      return Center(
        child: Text('No changes', style: TextStyle(color: c.textSecondary)),
      );
    }
    final initialPath = widget.initialPath;
    final center =
        initialPath != null && files.any((file) => file.path == initialPath)
        ? _keyFor(initialPath)
        : null;
    return CustomScrollView(
      center: center,
      slivers: [
        for (var i = 0; i < files.length; i++)
          SliverMainAxisGroup(
            key: _keyFor(files[i].path),
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                floating: true,
                delegate: _DiffFileHeaderDelegate(
                  file: DiffSummaryFile(
                    path: files[i].path,
                    additions: files[i].additions,
                    deletions: files[i].deletions,
                  ),
                  collapsed: _collapsedPaths.contains(files[i].path),
                  onTap: () => _toggleSection(files[i].path),
                  onOpenFile: widget.onOpenFile == null
                      ? null
                      : () => widget.onOpenFile!(
                          files[i].sourcePath ?? files[i].path,
                        ),
                ),
              ),
              if (!_collapsedPaths.contains(files[i].path))
                SliverToBoxAdapter(
                  child: _DiffSectionBody(
                    lines: files[i].lines,
                    last: i == files.length - 1,
                    tabActive: widget.tabActive,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  GlobalKey _keyFor(String path) =>
      _sectionKeys.putIfAbsent(path, GlobalKey.new);

  void _toggleSection(String path) {
    setState(() {
      if (!_collapsedPaths.add(path)) _collapsedPaths.remove(path);
    });
  }
}

class _DiffFileHeaderDelegate extends SliverPersistentHeaderDelegate {
  static const double height = 58;

  final DiffSummaryFile file;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback? onOpenFile;

  _DiffFileHeaderDelegate({
    required this.file,
    required this.collapsed,
    required this.onTap,
    this.onOpenFile,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return _FileHeader(
      file: file,
      collapsed: collapsed,
      onTap: onTap,
      onOpenFile: onOpenFile,
    );
  }

  @override
  bool shouldRebuild(covariant _DiffFileHeaderDelegate oldDelegate) {
    return oldDelegate.file.path != file.path ||
        oldDelegate.file.additions != file.additions ||
        oldDelegate.file.deletions != file.deletions ||
        oldDelegate.collapsed != collapsed ||
        oldDelegate.onOpenFile != onOpenFile;
  }
}

class _DiffSectionBody extends StatelessWidget {
  final List<String> lines;
  final bool last;
  final bool tabActive;

  const _DiffSectionBody({
    required this.lines,
    required this.last,
    required this.tabActive,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : MotifSpacing.md),
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: DiffTextView(lines: lines, tabActive: tabActive),
      ),
    );
  }
}

class _ChangedFileRow extends StatelessWidget {
  final DiffSummaryFile file;
  final VoidCallback onTap;
  final bool selected;

  const _ChangedFileRow({
    super.key,
    required this.file,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Material(
      color: selected ? c.accentFill(0.12) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MotifSpacing.md,
            vertical: MotifSpacing.sm,
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c.accentFill(0.12),
                  borderRadius: BorderRadius.circular(MotifRadius.xs),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.insert_drive_file_outlined,
                  size: 16,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: MotifSpacing.sm),
              Expanded(child: _PathTitle(path: file.path)),
              const SizedBox(width: MotifSpacing.sm),
              _ChangeStats(
                additions: file.additions,
                deletions: file.deletions,
              ),
              const SizedBox(width: MotifSpacing.xs),
              Icon(
                selected ? Icons.check_rounded : Icons.chevron_right,
                size: 18,
                color: selected ? c.accent : c.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PathTitle extends StatelessWidget {
  final String path;

  const _PathTitle({required this.path});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final slash = path.lastIndexOf('/');
    final dir = slash <= 0 ? '' : path.substring(0, slash);
    final name = slash < 0 ? path : path.substring(slash + 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: MotifType.mono.copyWith(
            color: c.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (dir.isNotEmpty)
          Text(
            dir,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MotifType.micro.copyWith(
              color: c.textTertiary,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w400,
              height: 1.25,
            ),
          ),
      ],
    );
  }
}

class _ChangeStats extends StatelessWidget {
  final int additions;
  final int deletions;

  const _ChangeStats({required this.additions, required this.deletions});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ChangePill(text: '+$additions', color: c.success),
        const SizedBox(width: MotifSpacing.xs),
        _ChangePill(text: '-$deletions', color: c.danger),
      ],
    );
  }
}

class _ChangePill extends StatelessWidget {
  final String text;
  final Color color;

  const _ChangePill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 32),
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.xs,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(MotifRadius.xs),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        maxLines: 1,
        style: MotifType.micro.copyWith(
          color: color,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w700,
          height: 1.15,
        ),
      ),
    );
  }
}

/// Shared changed-file sidebar used by Session and Codex diff surfaces.
class DiffFileSidebar extends StatelessWidget {
  const DiffFileSidebar({
    required this.summary,
    required this.onOpenFile,
    this.selectedPath,
    super.key,
  });

  final List<DiffSummaryFile> summary;
  final ValueChanged<String> onOpenFile;
  final String? selectedPath;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _SummaryBar(summary: summary),
      Expanded(
        child: DiffFileList(
          summary: summary,
          selectedPath: selectedPath,
          onOpenFile: onOpenFile,
        ),
      ),
    ],
  );
}

/// Shared changed-file list used by [DiffFileSidebar].
class DiffFileList extends StatelessWidget {
  final List<DiffSummaryFile> summary;
  final ValueChanged<String> onOpenFile;
  final String? selectedPath;

  const DiffFileList({
    required this.summary,
    required this.onOpenFile,
    this.selectedPath,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: MotifSpacing.xs),
      itemCount: summary.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, thickness: 1, indent: 44, color: c.border),
      itemBuilder: (context, i) {
        final f = summary[i];
        return _ChangedFileRow(
          key: ValueKey('diff-list-file-${f.path}'),
          file: f,
          onTap: () => onOpenFile(f.path),
          selected: f.path == selectedPath,
        );
      },
    );
  }
}

class _DiffFileTree extends StatelessWidget {
  final List<DiffSummaryFile> summary;
  final Set<String> expandedDirs;
  final ValueChanged<String> onToggleDir;
  final ValueChanged<String> onOpenFile;

  const _DiffFileTree({
    required this.summary,
    required this.expandedDirs,
    required this.onToggleDir,
    required this.onOpenFile,
  });

  @override
  Widget build(BuildContext context) {
    final root = _DiffTreeNode('');
    for (final file in summary) {
      root.add(file);
    }
    return ListView(children: _buildRows(context, root, '', 0));
  }

  List<Widget> _buildRows(
    BuildContext context,
    _DiffTreeNode node,
    String parentPath,
    int depth,
  ) {
    final rows = <Widget>[];
    final children = node.children.values.toList()
      ..sort((a, b) {
        if (a.isFile != b.isFile) return a.isFile ? 1 : -1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    for (final child in children) {
      final path = parentPath.isEmpty
          ? child.name
          : '$parentPath/${child.name}';
      if (child.isFile) {
        rows.add(
          _DiffTreeFileRow(
            file: child.file!,
            name: child.name,
            depth: depth,
            onTap: () => onOpenFile(child.file!.path),
          ),
        );
        continue;
      }
      final expanded = expandedDirs.contains(path);
      rows.add(
        _DiffTreeDirRow(
          node: child,
          path: path,
          depth: depth,
          expanded: expanded,
          onTap: () => onToggleDir(path),
        ),
      );
      if (expanded) {
        rows.addAll(_buildRows(context, child, path, depth + 1));
      }
    }
    return rows;
  }
}

class _DiffTreeDirRow extends StatelessWidget {
  final _DiffTreeNode node;
  final String path;
  final int depth;
  final bool expanded;
  final VoidCallback onTap;

  const _DiffTreeDirRow({
    required this.node,
    required this.path,
    required this.depth,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return InkWell(
      key: ValueKey('diff-tree-dir-$path'),
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(
          left: MotifSpacing.md + depth * MotifSpacing.lg,
          right: MotifSpacing.md,
          top: MotifSpacing.sm,
          bottom: MotifSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.folder_open : Icons.folder,
              size: 19,
              color: c.accent,
            ),
            const SizedBox(width: MotifSpacing.sm),
            Expanded(
              child: Text(
                node.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MotifType.subhead.copyWith(
                  color: c.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _ChangeStats(additions: node.additions, deletions: node.deletions),
          ],
        ),
      ),
    );
  }
}

class _DiffTreeFileRow extends StatelessWidget {
  final DiffSummaryFile file;
  final String name;
  final int depth;
  final VoidCallback onTap;

  const _DiffTreeFileRow({
    required this.file,
    required this.name,
    required this.depth,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return InkWell(
      key: ValueKey('diff-tree-file-${file.path}'),
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(
          left: MotifSpacing.md + depth * MotifSpacing.lg,
          right: MotifSpacing.md,
          top: MotifSpacing.sm,
          bottom: MotifSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 18,
              color: c.textSecondary,
            ),
            const SizedBox(width: MotifSpacing.sm),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MotifType.mono.copyWith(color: c.textPrimary),
              ),
            ),
            _ChangeStats(additions: file.additions, deletions: file.deletions),
          ],
        ),
      ),
    );
  }
}

class _DiffTreeNode {
  final String name;
  final Map<String, _DiffTreeNode> children = {};
  DiffSummaryFile? file;

  _DiffTreeNode(this.name);

  bool get isFile => file != null;
  int get additions =>
      (file?.additions ?? 0) +
      children.values.fold<int>(0, (total, node) => total + node.additions);
  int get deletions =>
      (file?.deletions ?? 0) +
      children.values.fold<int>(0, (total, node) => total + node.deletions);

  void add(DiffSummaryFile file) {
    final parts = file.path
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return;
    var node = this;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      node = node.children.putIfAbsent(part, () => _DiffTreeNode(part));
      if (i == parts.length - 1) node.file = file;
    }
  }
}

class _DiffTitle extends StatelessWidget {
  final bool staged;
  final ValueChanged<bool> onChanged;

  const _DiffTitle({required this.staged, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 224;
        final showTitle = constraints.maxWidth >= 92;
        return Row(
          children: [
            if (showTitle)
              Expanded(
                child: Text(
                  compact ? 'Diff' : 'Git diff',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (showTitle) const SizedBox(width: MotifSpacing.sm),
            compact
                ? _StageToggleButton(staged: staged, onChanged: onChanged)
                : _StageSelector(staged: staged, onChanged: onChanged),
          ],
        );
      },
    );
  }
}

class _EmbeddedDiffHeader extends StatelessWidget {
  final bool staged;
  final ValueChanged<bool> onChanged;
  final List<Widget> actions;

  const _EmbeddedDiffHeader({
    required this.staged,
    required this.onChanged,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return LayoutBuilder(
      builder: (context, constraints) {
        const horizontalPadding = MotifSpacing.md * 2;
        const fullTitleWidth = 108.0;
        const iconTitleWidth = 22.0;
        final actionsWidth = actions.length * 48.0;
        final showTitleText =
            constraints.maxWidth >=
            horizontalPadding +
                fullTitleWidth +
                156.0 +
                actionsWidth +
                MotifSpacing.sm * 2;
        final showTitleIcon =
            showTitleText ||
            constraints.maxWidth >=
                horizontalPadding +
                    iconTitleWidth +
                    136.0 +
                    actionsWidth +
                    MotifSpacing.sm * 2;
        final titleWidth = showTitleText
            ? fullTitleWidth
            : (showTitleIcon ? iconTitleWidth : 0.0);
        final spacing =
            (showTitleIcon ? MotifSpacing.sm : 0.0) + MotifSpacing.xs;
        final selectorWidth =
            (constraints.maxWidth -
                    horizontalPadding -
                    titleWidth -
                    actionsWidth -
                    spacing)
                .clamp(112.0, 156.0)
                .toDouble();
        final titleTextStyle = MotifType.body.copyWith(
          color: c.textPrimary,
          fontWeight: FontWeight.w700,
        );
        return MotifPanelHeader(
          height: 52,
          child: Row(
            children: [
              if (showTitleIcon)
                SizedBox(
                  width: titleWidth,
                  child: Row(
                    children: [
                      Icon(
                        Icons.difference_outlined,
                        size: 18,
                        color: c.textSecondary,
                      ),
                      if (showTitleText) ...[
                        const SizedBox(width: MotifSpacing.sm),
                        Expanded(
                          child: Text(
                            'Git diff',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleTextStyle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              if (showTitleIcon) const SizedBox(width: MotifSpacing.sm),
              _StageSelector(
                staged: staged,
                onChanged: onChanged,
                width: selectorWidth,
              ),
              const Spacer(),
              Row(mainAxisSize: MainAxisSize.min, children: actions),
            ],
          ),
        );
      },
    );
  }
}

class _StageSelector extends StatelessWidget {
  final bool staged;
  final ValueChanged<bool> onChanged;
  final double width;

  const _StageSelector({
    required this.staged,
    required this.onChanged,
    this.width = 156,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: false,
            label: Text(
              'Working',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ButtonSegment(
            value: true,
            label: Text('Staged', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
        selected: {staged},
        style: ButtonStyle(
          // No hard-coded height: the default minimumSize (40) minus the
          // compact visualDensity (-8) gives 32, and shrinkWrap stops the tap
          // target padding it back up to 48.
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: MotifSpacing.sm),
          ),
          textStyle: WidgetStateProperty.all(
            MotifType.caption.copyWith(fontWeight: FontWeight.w600),
          ),
          visualDensity: VisualDensity.compact,
        ),
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );
  }
}

class _StageToggleButton extends StatelessWidget {
  final bool staged;
  final ValueChanged<bool> onChanged;

  const _StageToggleButton({required this.staged, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Tooltip(
      message: staged ? 'Showing staged diff' : 'Showing working diff',
      child: IconButton(
        icon: Icon(
          staged ? Icons.inventory_2_outlined : Icons.edit_note_outlined,
        ),
        style: context.iconButtonStyle(
          foregroundColor: c.accent,
          backgroundColor: c.accentFill(),
        ),
        onPressed: () => onChanged(!staged),
      ),
    );
  }
}

class _SummaryBar extends StatelessWidget {
  final List<DiffSummaryFile> summary;
  const _SummaryBar({required this.summary});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final adds = summary.fold<int>(0, (a, f) => a + f.additions);
    final dels = summary.fold<int>(0, (a, f) => a + f.deletions);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.surfaceElevated,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.difference_outlined, size: 16, color: c.textSecondary),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: Text(
              '${summary.length} changed file${summary.length == 1 ? '' : 's'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MotifType.caption.copyWith(
                color: c.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          _ChangeStats(additions: adds, deletions: dels),
        ],
      ),
    );
  }
}

class _FileHeader extends StatelessWidget {
  final DiffSummaryFile file;
  final bool collapsed;
  final VoidCallback? onTap;
  final VoidCallback? onOpenFile;

  const _FileHeader({
    required this.file,
    this.collapsed = false,
    this.onTap,
    this.onOpenFile,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.surfaceElevated,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.insert_drive_file_outlined, size: 18, color: c.accent),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(child: _PathTitle(path: file.path)),
          const SizedBox(width: MotifSpacing.sm),
          _ChangeStats(additions: file.additions, deletions: file.deletions),
          if (onOpenFile != null) ...[
            const SizedBox(width: MotifSpacing.xs),
            IconButton(
              key: ValueKey('diff-open-file-${file.path}'),
              tooltip: 'View file',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(
                width: MotifControlSize.sm,
                height: MotifControlSize.sm,
              ),
              padding: EdgeInsets.zero,
              iconSize: MotifIconSize.sm,
              onPressed: onOpenFile,
              icon: const Icon(Icons.open_in_new_rounded),
            ),
          ],
          if (onTap != null) ...[
            const SizedBox(width: MotifSpacing.sm),
            Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              size: 18,
              color: c.textSecondary,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('diff-section-header-${file.path}'),
        onTap: onTap,
        child: content,
      ),
    );
  }
}
