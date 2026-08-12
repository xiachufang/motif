import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/resource_documents.dart';
import '../../state/workspace/workspace_api.dart';
import '../theme/motif_theme.dart';
import '../widgets/syntax_highlight.dart';
import '../widgets/tab_selection_area.dart';
import '../widgets/top_toast.dart';

/// Read-only file preview with an edit/save toggle (mirrors PreviewPane).
class PreviewPane extends StatefulWidget {
  final String path;
  final WorkspaceApi workspace;
  final bool tabActive;
  const PreviewPane({
    super.key,
    required this.path,
    required this.workspace,
    this.tabActive = true,
  });

  @override
  State<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends State<PreviewPane> {
  String _sha = '';
  bool _binary = false;
  bool _truncated = false;
  bool _editing = false;
  bool _loading = true;
  String? _error;
  Uint8List _bytes = Uint8List(0);
  String? _mime;
  Uint8List? _imageBytes;
  final TextEditingController _editor = TextEditingController();

  static const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
  bool get _isImage {
    final dot = widget.path.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExts.contains(widget.path.substring(dot + 1).toLowerCase());
  }

  WorkspaceApi get _workspace => widget.workspace;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabActive && !widget.tabActive) {
      final selection = _editor.selection;
      if (selection.isValid && !selection.isCollapsed) {
        _editor.selection = TextSelection.collapsed(
          offset: selection.extentOffset.clamp(0, _editor.text.length),
        );
      }
    }
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _workspace.read(widget.path);
      final raw = base64Decode(r.contentB64);
      final isImg =
          _isImage && (r.binary || (r.mime?.startsWith('image/') ?? false));
      final text = (r.binary || isImg)
          ? ''
          : utf8.decode(raw, allowMalformed: true);
      if (!mounted) return;
      setState(() {
        _bytes = raw;
        _mime = r.mime;
        _sha = r.sha256;
        _binary = r.binary && !isImg;
        _imageBytes = isImg ? raw : null;
        _truncated = r.truncated;
        _editor.text = text;
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

  Future<void> _save({bool force = false}) async {
    try {
      final b64 = base64Encode(utf8.encode(_editor.text));
      // First try a guarded write (force:false): the server rejects it if the
      // file changed since we read it, so we can prompt instead of clobbering.
      final newSha = await _workspace.write(
        widget.path,
        b64,
        expectedSha256: force ? null : _sha,
        force: force,
      );
      if (!mounted) return;
      setState(() {
        _bytes = Uint8List.fromList(utf8.encode(_editor.text));
        _sha = newSha;
        _editing = false;
      });
      showMotifToast(context, 'Saved');
    } catch (e) {
      if (!mounted) return;
      if (!force) {
        // Likely a sha256 conflict — the file changed on the server.
        final action = await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('File changed on server'),
            content: const Text(
              'This file was modified since you opened it. Overwrite with your '
              'changes, or discard yours and reload?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'discard'),
                child: const Text('Discard & reload'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'overwrite'),
                child: const Text('Overwrite'),
              ),
            ],
          ),
        );
        if (action == 'overwrite') {
          await _save(force: true);
        } else if (action == 'discard') {
          await _load();
          if (mounted) setState(() => _editing = false);
        }
        return;
      }
      showMotifToast(context, 'Save failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Scaffold(
      backgroundColor: c.surface,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          widget.path.split('/').last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const ValueKey('preview-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh file',
            style: context.iconButtonStyle(foregroundColor: c.textSecondary),
            onPressed: _loading ? null : _load,
          ),
          if (!_binary && _imageBytes == null) ...[
            const SizedBox(width: MotifSpacing.xs),
            IconButton(
              key: const ValueKey('preview-edit-save'),
              icon: Icon(_editing ? Icons.save_outlined : Icons.edit_outlined),
              tooltip: _editing ? 'Save file' : 'Edit file',
              style: context.iconButtonStyle(
                foregroundColor: _editing ? c.textOnAccent : c.accent,
                backgroundColor: _editing ? c.accent : c.accentFill(),
              ),
              onPressed: _editing
                  ? _save
                  : () => setState(() => _editing = true),
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Text(_error!, style: TextStyle(color: c.danger)),
            )
          : _editing
          ? TextField(
              controller: _editor,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.all(MotifSpacing.sm),
                border: InputBorder.none,
              ),
            )
          : FilePreviewBody(
              document: FilePreviewDocument(
                path: widget.path,
                bytes: _bytes,
                mime: _mime,
                binary: _binary,
                truncated: _truncated,
                image: _imageBytes != null,
              ),
              tabActive: widget.tabActive,
            ),
    );
  }
}

/// Shared read-only renderer for files loaded by Session or Codex.
class FilePreviewBody extends StatefulWidget {
  const FilePreviewBody({
    required this.document,
    this.tabActive = true,
    super.key,
  });

  final FilePreviewDocument document;
  final bool tabActive;

  @override
  State<FilePreviewBody> createState() => _FilePreviewBodyState();
}

class _FilePreviewBodyState extends State<FilePreviewBody> {
  final ScrollController _scrollController = ScrollController();
  String? _highlightedSource;
  String? _highlightedPath;
  MotifColors? _highlightedColors;
  TextSpan? _highlightedSpan;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  TextSpan _highlightedCode(String content, MotifColors colors) {
    if (_highlightedSpan == null ||
        _highlightedSource != content ||
        _highlightedPath != widget.document.path ||
        _highlightedColors != colors) {
      _highlightedSource = content;
      _highlightedPath = widget.document.path;
      _highlightedColors = colors;
      _highlightedSpan = MotifSyntaxHighlight.build(
        source: content,
        path: widget.document.path,
        colors: colors,
      );
    }
    return _highlightedSpan!;
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    final c = context.motif;
    if (document.image) {
      return Container(
        key: const ValueKey('preview-background'),
        color: c.surface,
        child: InteractiveViewer(
          maxScale: 8,
          child: Center(child: Image.memory(document.bytes)),
        ),
      );
    }
    if (document.binary) {
      return ColoredBox(
        key: const ValueKey('preview-background'),
        color: c.surface,
        child: Center(
          child: Text(
            'Binary file (${document.path})',
            style: TextStyle(color: c.textSecondary),
          ),
        ),
      );
    }
    final content = document.text;
    return ColoredBox(
      key: const ValueKey('preview-background'),
      color: c.surface,
      child: Column(
        children: [
          if (document.truncated)
            Container(
              width: double.infinity,
              color: c.danger.withValues(alpha: 0.15),
              padding: const EdgeInsets.all(MotifSpacing.sm),
              child: Text(
                'Truncated preview',
                style: MotifType.caption.copyWith(
                  color: c.danger,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          Expanded(
            child: TabSelectionArea(
              tabActive: widget.tabActive,
              child: SizedBox.expand(
                child: Scrollbar(
                  key: const ValueKey('preview-scrollbar'),
                  controller: _scrollController,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(
                        MotifSpacing.sm,
                        MotifSpacing.sm,
                        MotifSpacing.lg,
                        MotifSpacing.sm,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text.rich(
                          key: const ValueKey('preview-highlighted-code'),
                          _highlightedCode(content, c),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
