import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/motif_proto.dart';
import '../../state/motif_client.dart';
import '../theme/motif_theme.dart';

/// Unified git diff viewer with staged/working toggle + per-file summary.
/// Mirrors GitDiffPanel. Re-fetches when `git.changed` bumps the tick.
class GitDiffPanel extends StatefulWidget {
  final String? cwd;
  final bool initialStaged;
  final String? path;
  final MotifClient motif;
  final bool embedded;

  const GitDiffPanel({
    super.key,
    this.cwd,
    this.initialStaged = false,
    this.path,
    required this.motif,
    this.embedded = false,
  });

  @override
  State<GitDiffPanel> createState() => _GitDiffPanelState();
}

class _GitDiffPanelState extends State<GitDiffPanel> {
  late bool _staged;
  bool _byFile = false;
  int _fileIndex = 0;
  String _patch = '';
  List<DiffSummaryFile> _summary = const [];
  bool _loading = true;
  String? _error;
  int _lastTick = -1;

  late final MotifClient _motif;

  @override
  void initState() {
    super.initState();
    _staged = widget.initialStaged;
    _motif = widget.motif;
    _motif.addListener(_onTick);
    _load();
  }

  void _onTick() {
    if (_motif.gitChangeTick != _lastTick) _load();
  }

  @override
  void dispose() {
    _motif.removeListener(_onTick);
    super.dispose();
  }

  Future<void> _load() async {
    _lastTick = _motif.gitChangeTick;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await _motif.gitDiffSummary(
        path: widget.path,
        staged: _staged,
        cwd: widget.cwd,
      );
      if (_byFile && _fileIndex >= summary.length) _fileIndex = 0;
      final path = _byFile && summary.isNotEmpty
          ? summary[_fileIndex].path
          : widget.path;
      final patch = await _motif.gitDiff(
        path: path,
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

  Future<void> _pickFile() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _summary.length,
          itemBuilder: (_, i) {
            final f = _summary[i];
            return ListTile(
              selected: i == _fileIndex,
              title: Text(
                f.path,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text('+${f.additions} -${f.deletions}'),
              onTap: () => Navigator.pop(context, i),
            );
          },
        ),
      ),
    );
    if (picked != null && picked != _fileIndex) {
      setState(() => _fileIndex = picked);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(
            child: Text(_error!, style: TextStyle(color: c.danger)),
          )
        : Column(
            children: [
              if (_byFile && _summary.isNotEmpty)
                _FileHeader(
                  file: _summary[_fileIndex.clamp(0, _summary.length - 1)],
                  index: _fileIndex,
                  count: _summary.length,
                  onTap: _pickFile,
                )
              else if (_summary.isNotEmpty)
                _SummaryBar(summary: _summary),
              Expanded(
                child: _patch.isEmpty
                    ? Center(
                        child: Text(
                          'No changes',
                          style: TextStyle(color: c.textSecondary),
                        ),
                      )
                    : _DiffText(patch: _patch),
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

  List<Widget> _actions() => [
    IconButton(
      icon: Icon(
        _byFile ? Icons.view_agenda_outlined : Icons.description_outlined,
      ),
      tooltip: _byFile ? 'Show all' : 'By file',
      onPressed: () {
        setState(() {
          _byFile = !_byFile;
          _fileIndex = 0;
        });
        _load();
      },
    ),
    if (_byFile && _summary.length > 1)
      IconButton(
        icon: const Icon(Icons.list),
        tooltip: 'Files',
        onPressed: _pickFile,
      ),
  ];

  void _setStaged(bool staged) {
    setState(() => _staged = staged);
    _load();
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
                : _StageSelector(
                    staged: staged,
                    onChanged: onChanged,
                    compact: true,
                  ),
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
        final centeredSelectorMinWidth = math.max(
          360.0,
          actions.length * 96.0 + 156.0,
        );
        final narrow = constraints.maxWidth < centeredSelectorMinWidth;
        final titleTextStyle = TextStyle(
          color: c.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        );
        final titleContent = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.difference_outlined, size: 18, color: c.textSecondary),
            const SizedBox(width: MotifSpacing.sm),
            Text(
              'Git diff',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleTextStyle,
            ),
          ],
        );
        final title = Row(
          children: [
            Icon(Icons.difference_outlined, size: 18, color: c.textSecondary),
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
        );
        final titleWithActions = Row(
          children: [
            Expanded(child: title),
            const SizedBox(width: MotifSpacing.xs),
            ...actions,
          ],
        );
        return Container(
          height: narrow ? 88 : 48,
          decoration: BoxDecoration(
            color: c.background,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: narrow
              ? Column(
                  children: [
                    SizedBox(
                      height: 48,
                      child: Padding(
                        padding: const EdgeInsets.only(left: MotifSpacing.md),
                        child: titleWithActions,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 32,
                      child: Center(
                        child: _StageSelector(
                          staged: staged,
                          onChanged: onChanged,
                          compact: true,
                        ),
                      ),
                    ),
                  ],
                )
              : Stack(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: MotifSpacing.md),
                        child: titleContent,
                      ),
                    ),
                    Center(
                      child: _StageSelector(
                        staged: staged,
                        onChanged: onChanged,
                        compact: true,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: actions,
                      ),
                    ),
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
  final bool compact;

  const _StageSelector({
    required this.staged,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final height = compact ? 32.0 : 40.0;
    final button = SegmentedButton<bool>(
      showSelectedIcon: !compact,
      segments: const [
        ButtonSegment(
          value: false,
          label: Text('Working', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        ButtonSegment(
          value: true,
          label: Text('Staged', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
      selected: {staged},
      style: ButtonStyle(
        minimumSize: WidgetStateProperty.all(Size(0, height)),
        padding: WidgetStateProperty.all(
          EdgeInsets.symmetric(horizontal: compact ? MotifSpacing.sm : 16),
        ),
        textStyle: WidgetStateProperty.all(
          TextStyle(fontSize: compact ? 12 : 14, fontWeight: FontWeight.w600),
        ),
        visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      ),
      onSelectionChanged: (s) => onChanged(s.first),
    );
    return SizedBox(width: compact ? 156 : null, height: height, child: button);
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
        style: IconButton.styleFrom(
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
      color: c.surface,
      child: Text(
        '${summary.length} file(s)  +$adds  -$dels',
        style: TextStyle(
          color: c.textSecondary,
          fontFamily: 'monospace',
          fontSize: 12,
        ),
      ),
    );
  }
}

class _FileHeader extends StatelessWidget {
  final DiffSummaryFile file;
  final int index;
  final int count;
  final VoidCallback onTap;
  const _FileHeader({
    required this.file,
    required this.index,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: MotifSpacing.md,
          vertical: MotifSpacing.sm,
        ),
        color: c.surface,
        child: Row(
          children: [
            Expanded(
              child: Text(
                file.path,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: MotifSpacing.sm),
            Text(
              '+${file.additions} -${file.deletions}',
              style: TextStyle(color: c.textTertiary, fontSize: 12),
            ),
            const SizedBox(width: MotifSpacing.sm),
            Text(
              '${index + 1}/$count',
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
            Icon(Icons.expand_more, size: 18, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _DiffText extends StatelessWidget {
  final String patch;
  const _DiffText({required this.patch});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final lines = patch.split('\n');
    return LayoutBuilder(
      builder: (context, constraints) {
        const fontSize = 12.0;
        final longestLine = lines.fold<int>(
          0,
          (longest, line) => math.max(longest, line.length),
        );
        final contentWidth = math.max(
          constraints.maxWidth,
          longestLine * fontSize * 0.62 + MotifSpacing.sm * 2,
        );
        return SelectionArea(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: contentWidth,
              height: constraints.maxHeight,
              child: ListView.builder(
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final line = lines[i];
                  final Color color;
                  if (line.startsWith('+') && !line.startsWith('+++')) {
                    color = const Color(0xFF4CAF50);
                  } else if (line.startsWith('-') && !line.startsWith('---')) {
                    color = c.danger;
                  } else if (line.startsWith('@@')) {
                    color = c.accent;
                  } else {
                    color = c.textSecondary;
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: MotifSpacing.sm,
                    ),
                    child: Text(
                      line.isEmpty ? ' ' : line,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: fontSize,
                        color: color,
                        height: 1.3,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
