import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../state/motif_client.dart';
import '../theme/motif_theme.dart';
import '../widgets/top_toast.dart';

/// Read-only file preview with an edit/save toggle (mirrors PreviewPane).
class PreviewPane extends StatefulWidget {
  final String path;
  final MotifClient motif;
  const PreviewPane({super.key, required this.path, required this.motif});

  @override
  State<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends State<PreviewPane> {
  String _content = '';
  String _sha = '';
  bool _binary = false;
  bool _truncated = false;
  bool _editing = false;
  bool _loading = true;
  String? _error;
  Uint8List? _imageBytes;
  final TextEditingController _editor = TextEditingController();

  static const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
  bool get _isImage {
    final dot = widget.path.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExts.contains(widget.path.substring(dot + 1).toLowerCase());
  }

  MotifClient get _motif => widget.motif;

  @override
  void initState() {
    super.initState();
    _load();
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
      final r = await _motif.fsRead(widget.path);
      final raw = base64Decode(r.contentB64);
      final isImg =
          _isImage && (r.binary || (r.mime?.startsWith('image/') ?? false));
      final text = (r.binary || isImg)
          ? ''
          : utf8.decode(raw, allowMalformed: true);
      if (!mounted) return;
      setState(() {
        _content = text;
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
      final newSha = await _motif.fsWrite(
        widget.path,
        b64,
        expectedSha256: force ? null : _sha,
        force: force,
      );
      if (!mounted) return;
      setState(() {
        _content = _editor.text;
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
      appBar: AppBar(
        title: Text(widget.path.split('/').last),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          if (!_binary && _imageBytes == null)
            IconButton(
              icon: Icon(_editing ? Icons.save : Icons.edit),
              onPressed: _editing
                  ? _save
                  : () => setState(() => _editing = true),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Text(_error!, style: TextStyle(color: c.danger)),
            )
          : _imageBytes != null
          ? Container(
              color: c.background,
              child: InteractiveViewer(
                maxScale: 8,
                child: Center(child: Image.memory(_imageBytes!)),
              ),
            )
          : _binary
          ? Center(
              child: Text(
                'Binary file (${widget.path})',
                style: TextStyle(color: c.textSecondary),
              ),
            )
          : Column(
              children: [
                if (_truncated)
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
                  child: _editing
                      ? TextField(
                          controller: _editor,
                          maxLines: null,
                          expands: true,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.all(MotifSpacing.sm),
                            border: InputBorder.none,
                          ),
                        )
                      : SelectionArea(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(MotifSpacing.sm),
                            child: Text(
                              _content,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                color: c.textPrimary,
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
