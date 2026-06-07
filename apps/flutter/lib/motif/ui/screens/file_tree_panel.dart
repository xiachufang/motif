import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/motif_proto.dart';
import '../../state/motif_client.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';

/// Lazy file-tree browser rooted at a directory (mirrors FileTreePanel).
/// Tapping a file calls [onOpen] (and pops); tapping a dir expands it.
class FileTreePanel extends StatefulWidget {
  final String root;
  final void Function(String path) onOpen;
  final MotifClient motif;
  final bool embedded;
  const FileTreePanel({
    super.key,
    required this.root,
    required this.onOpen,
    required this.motif,
    this.embedded = false,
  });

  @override
  State<FileTreePanel> createState() => _FileTreePanelState();
}

class _FileTreePanelState extends State<FileTreePanel> {
  // path -> children (null = not loaded, [] = loaded empty)
  final Map<String, List<TreeEntry>?> _children = {};
  final Set<String> _expanded = {};
  bool _loading = true;
  String? _error;

  late final MotifClient _motif;

  int _lastTreeTick = -1;

  @override
  void initState() {
    super.initState();
    _motif = widget.motif;
    _lastTreeTick = _motif.treeChangeTick;
    _motif.addListener(_onTreeChanged);
    _loadDir(widget.root).then((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _motif.removeListener(_onTreeChanged);
    super.dispose();
  }

  /// Re-pull every already-loaded directory when the server reports a
  /// filesystem change (mirrors the iOS FileTreePanel invalidation).
  void _onTreeChanged() {
    if (_motif.treeChangeTick == _lastTreeTick) return;
    _lastTreeTick = _motif.treeChangeTick;
    for (final dir in _children.keys.toList()) {
      _loadDir(dir);
    }
  }

  Future<void> _loadDir(String path) async {
    try {
      final entries = await _motif.fsTree(path, depth: 1);
      entries.sort((a, b) {
        if ((a.type == FileType.dir) != (b.type == FileType.dir)) {
          return a.type == FileType.dir ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (mounted) setState(() => _children[path] = entries);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _join(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  Future<void> _toggle(String path) async {
    if (_expanded.contains(path)) {
      setState(() => _expanded.remove(path));
    } else {
      setState(() => _expanded.add(path));
      if (_children[path] == null) await _loadDir(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final title =
        widget.root.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/';
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(
            child: Text(_error!, style: TextStyle(color: c.danger)),
          )
        : ListView(children: _buildRows(widget.root, 0));
    final actions = [_newEntryMenu()];
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(title: Text(title), actions: actions),
        body: body,
      );
    }
    return Column(
      children: [
        _EmbeddedPanelHeader(
          icon: Icons.folder_outlined,
          title: title,
          actions: actions,
        ),
        Expanded(child: body),
      ],
    );
  }

  PopupMenuButton<String> _newEntryMenu() => PopupMenuButton<String>(
    icon: const Icon(Icons.add),
    tooltip: 'New',
    onSelected: (v) {
      if (v == 'file') _newEntry(widget.root, isDir: false);
      if (v == 'folder') _newEntry(widget.root, isDir: true);
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'file', child: Text('New file')),
      PopupMenuItem(value: 'folder', child: Text('New folder')),
    ],
  );

  List<Widget> _buildRows(String dir, int depth) {
    final entries = _children[dir];
    if (entries == null) return const [];
    final rows = <Widget>[];
    for (final e in entries) {
      final path = _join(dir, e.name);
      final isDir = e.type == FileType.dir;
      final expanded = _expanded.contains(path);
      rows.add(_row(e, path, isDir, expanded, depth));
      if (isDir && expanded) {
        rows.addAll(_buildRows(path, depth + 1));
      }
    }
    return rows;
  }

  Widget _row(TreeEntry e, String path, bool isDir, bool expanded, int depth) {
    final c = context.motif;
    return InkWell(
      onTap: () {
        if (isDir) {
          _toggle(path);
        } else {
          widget.onOpen(path);
          if (!widget.embedded) Navigator.of(context).pop();
        }
      },
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
              isDir
                  ? (expanded ? Icons.folder_open : Icons.folder)
                  : Icons.insert_drive_file_outlined,
              size: 18,
              color: isDir ? c.accent : c.textSecondary,
            ),
            const SizedBox(width: MotifSpacing.sm),
            Expanded(
              child: Text(
                e.name,
                style: TextStyle(color: c.textPrimary, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (e.gitStatus != null && e.gitStatus != GitFileStatus.unmodified)
              Text(
                _gitGlyph(e.gitStatus!),
                style: TextStyle(
                  color: c.accent,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 18, color: c.textTertiary),
              onSelected: (v) {
                final parent = _parentOf(path);
                if (v == 'rename') _rename(path, e.name, parent);
                if (v == 'delete') _delete(path, parent);
                if (v == 'newfile') _newEntry(path, isDir: false);
                if (v == 'newfolder') _newEntry(path, isDir: true);
              },
              itemBuilder: (_) => [
                if (isDir) ...const [
                  PopupMenuItem(value: 'newfile', child: Text('New file')),
                  PopupMenuItem(value: 'newfolder', child: Text('New folder')),
                ],
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _parentOf(String path) {
    final p = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  Future<void> _refreshDir(String dir) async {
    await _loadDir(dir);
    if (mounted) setState(() {});
  }

  Future<void> _newEntry(String dir, {required bool isDir}) async {
    final name = await _prompt(isDir ? 'New folder name' : 'New file name');
    if (name == null || name.trim().isEmpty) return;
    final path = _join(dir, name.trim());
    try {
      if (isDir) {
        await _motif.fsMkdir(path);
      } else {
        await _motif.fsWrite(path, base64Encode(const []));
      }
      _expanded.add(dir);
      await _refreshDir(dir);
    } catch (e) {
      _snack('Create failed: $e');
    }
  }

  Future<void> _rename(String path, String current, String parent) async {
    final name = await _prompt('Rename', initial: current);
    if (name == null || name.trim().isEmpty || name.trim() == current) return;
    try {
      await _motif.fsRename(path, _join(parent, name.trim()));
      await _refreshDir(parent);
    } catch (e) {
      _snack('Rename failed: $e');
    }
  }

  Future<void> _delete(String path, String parent) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${path.split('/').last}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _motif.fsRemove(path);
      await _refreshDir(parent);
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Future<String?> _prompt(String title, {String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showAdaptiveModal<String>(
      context,
      builder: (context) => AdaptiveModal(
        title: title,
        content: MotifSection(
          title: 'Name',
          dividerIndent: MotifSpacing.lg,
          children: [_promptField(ctrl)],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _promptField(TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      child: TextField(
        controller: controller,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          isDense: true,
        ),
      ),
    );
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  String _gitGlyph(GitFileStatus s) => switch (s) {
    GitFileStatus.modified => 'M',
    GitFileStatus.added => 'A',
    GitFileStatus.deleted => 'D',
    GitFileStatus.renamed => 'R',
    GitFileStatus.copied => 'C',
    GitFileStatus.untracked => '?',
    GitFileStatus.ignored => '!',
    GitFileStatus.conflicted => 'U',
    GitFileStatus.unmodified => '',
  };
}

class _EmbeddedPanelHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> actions;

  const _EmbeddedPanelHeader({
    required this.icon,
    required this.title,
    required this.actions,
  });

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
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
