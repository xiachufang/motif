import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/motif_proto.dart';
import '../../state/motif_client.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';

/// A `cd` directory picker (mirrors ChangeDirectoryPanel): browse subdirectories
/// of a base path and send `cd '<path>'` to the active PTY on confirm.
class ChangeDirectoryPanel extends StatefulWidget {
  final String baseDir;
  final void Function(String path) onChoose;
  final MotifClient motif;
  const ChangeDirectoryPanel({
    super.key,
    required this.baseDir,
    required this.onChoose,
    required this.motif,
  });

  @override
  State<ChangeDirectoryPanel> createState() => _ChangeDirectoryPanelState();
}

class _ChangeDirectoryPanelState extends State<ChangeDirectoryPanel> {
  late String _input;
  final Map<String, List<TreeEntry>> _cache = {};
  final Set<String> _loading = {};
  final TextEditingController _pathController = TextEditingController();
  final FocusNode _pathFocusNode = FocusNode(debugLabel: 'Change directory');

  MotifClient get _motif => widget.motif;

  @override
  void initState() {
    super.initState();
    _input = _asDirectoryPath(widget.baseDir);
    _setPathField(_input);
    _load(_baseDir);
  }

  @override
  void dispose() {
    _pathController.dispose();
    _pathFocusNode.dispose();
    super.dispose();
  }

  Future<void> _load(String dir, {bool force = false}) async {
    if (dir.isEmpty) return;
    if (!force && _cache.containsKey(dir)) return;
    if (_loading.contains(dir)) return;
    setState(() => _loading.add(dir));
    try {
      final entries = await _motif.fsTree(dir, depth: 1, showHidden: false);
      if (!mounted) return;
      setState(() {
        _cache[dir] = entries.where((e) => e.type == FileType.dir).toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        _loading.remove(dir);
      });
    } catch (_) {
      if (mounted) setState(() => _loading.remove(dir));
    }
  }

  String _join(String dir, String name) =>
      dir == '/' ? '/$name' : (dir.endsWith('/') ? '$dir$name' : '$dir/$name');

  String _dirname(String path) {
    final trimmed = _withoutTrailingSeparator(path);
    if (trimmed.isEmpty) return '';
    final idx = trimmed.lastIndexOf('/');
    if (idx < 0) return '';
    return idx == 0 ? '/' : trimmed.substring(0, idx);
  }

  String _basename(String path) {
    final trimmed = _withoutTrailingSeparator(path);
    final idx = trimmed.lastIndexOf('/');
    return idx < 0 ? trimmed : trimmed.substring(idx + 1);
  }

  String _asDirectoryPath(String path) {
    if (path.isEmpty || path == '/') return '/';
    return path.endsWith('/') ? path : '$path/';
  }

  String _withoutTrailingSeparator(String path) =>
      path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;

  String _baseDirFor(String input) =>
      input.endsWith('/') ? _withoutTrailingSeparator(input) : _dirname(input);

  String _queryFor(String input) => input.endsWith('/') ? '' : _basename(input);

  String get _baseDir => _baseDirFor(_input);
  String get _query => _queryFor(_input);

  List<TreeEntry> get _candidates {
    final all = _cache[_baseDir] ?? const <TreeEntry>[];
    final query = _query;
    if (query.isEmpty) return all;
    final matches = _matcher(query);
    return all.where((entry) => matches(entry.name)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  bool Function(String name) _matcher(String pattern) {
    try {
      final regex = RegExp(pattern, caseSensitive: false);
      return regex.hasMatch;
    } on FormatException {
      final query = pattern.toLowerCase();
      return (name) => name.toLowerCase().contains(query);
    }
  }

  String? get _resolvedTarget {
    final baseDir = _baseDir;
    final query = _query;
    if (query.isEmpty) {
      return _cache.containsKey(baseDir) ? baseDir : null;
    }
    for (final entry in _cache[baseDir] ?? const <TreeEntry>[]) {
      if (entry.name.toLowerCase() == query.toLowerCase()) {
        return _join(baseDir, entry.name);
      }
    }
    return null;
  }

  String get _displayPath =>
      _resolvedTarget ?? _withoutTrailingSeparator(_input);

  void _setPathField(String value) {
    _pathController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _onPathChanged(String value) {
    setState(() => _input = value);
    unawaited(_load(_baseDirFor(value)));
  }

  void _enterFirst() {
    final candidates = _candidates;
    if (candidates.isEmpty) return;
    _drill(candidates.first.name);
  }

  void _drill(String name) {
    final next = _asDirectoryPath(_join(_baseDir, name));
    setState(() => _input = next);
    _setPathField(next);
    _pathFocusNode.requestFocus();
    unawaited(_load(_baseDirFor(next)));
  }

  void _goUp() {
    final baseDir = _baseDir;
    if (baseDir == '/') return;
    final next = _asDirectoryPath(_dirname(baseDir));
    setState(() => _input = next);
    _setPathField(next);
    _pathFocusNode.requestFocus();
    unawaited(_load(_baseDirFor(next)));
  }

  void _confirm() {
    final target = _resolvedTarget;
    if (target == null) return;
    widget.onChoose(target);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final candidates = _candidates;
    final hasLoadedBase = _cache.containsKey(_baseDir);
    final isLoadingBase = _loading.contains(_baseDir);
    return SafeArea(
      top: false,
      child: Column(
        children: [
          const SizedBox(height: MotifSpacing.sm),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: c.borderStrong,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          _Header(onCancel: () => Navigator.of(context).pop()),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MotifSpacing.lg,
              MotifSpacing.md,
              MotifSpacing.lg,
              MotifSpacing.md,
            ),
            child: Row(
              children: [
                Icon(Icons.chevron_right, color: c.accent, size: 22),
                const SizedBox(width: MotifSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _pathController,
                    focusNode: _pathFocusNode,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: c.textPrimary,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'path',
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: _onPathChanged,
                    onSubmitted: (_) => _enterFirst(),
                  ),
                ),
                if (isLoadingBase)
                  const Padding(
                    padding: EdgeInsets.only(left: MotifSpacing.sm),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (_baseDir != '/') _parentRow(c),
                if (candidates.isEmpty && hasLoadedBase && !isLoadingBase)
                  Padding(
                    padding: const EdgeInsets.all(MotifSpacing.lg),
                    child: Text(
                      _query.isEmpty ? 'No subdirectories' : 'No match',
                      style: TextStyle(color: c.textSecondary, fontSize: 13),
                    ),
                  ),
                for (var i = 0; i < candidates.length; i++)
                  _candidateRow(candidates[i], isFirst: i == 0, colors: c),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(MotifSpacing.lg),
            child: FilledButton(
              key: const ValueKey('change-directory-confirm'),
              onPressed: _resolvedTarget == null ? null : _confirm,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(MotifControlSize.md),
                padding: const EdgeInsets.symmetric(
                  horizontal: MotifSpacing.lg,
                  vertical: MotifSpacing.sm,
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.subdirectory_arrow_right, size: 18),
                  const SizedBox(width: MotifSpacing.sm),
                  const Text('cd', style: TextStyle(fontFamily: 'monospace')),
                  const SizedBox(width: MotifSpacing.sm),
                  Expanded(
                    child: Text(
                      _displayPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _parentRow(MotifColors colors) {
    return ListTile(
      leading: Icon(
        Icons.subdirectory_arrow_left,
        color: colors.textSecondary,
        size: 22,
      ),
      title: Row(
        children: [
          Text(
            '..',
            style: TextStyle(
              color: colors.textPrimary,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: MotifSpacing.sm),
          Text(
            'parent',
            style: TextStyle(color: colors.textTertiary, fontSize: 12),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: MotifSpacing.lg),
      onTap: _goUp,
    );
  }

  Widget _candidateRow(
    TreeEntry entry, {
    required bool isFirst,
    required MotifColors colors,
  }) {
    return ListTile(
      tileColor: isFirst ? colors.accentFill(0.12) : null,
      leading: Icon(Icons.folder, color: colors.accent, size: 22),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.textPrimary, fontFamily: 'monospace'),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isFirst) ...[
            Icon(Icons.keyboard_return, size: 16, color: colors.accent),
            const SizedBox(width: MotifSpacing.sm),
          ],
          Icon(Icons.chevron_right, size: 16, color: colors.textTertiary),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: MotifSpacing.lg),
      onTap: () => _drill(entry.name),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onCancel;

  const _Header({required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return AdaptiveModalHeader(title: 'Change directory', onClose: onCancel);
  }
}
