import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../codex/codex_navigation.dart';
import '../../codex/codex_service_state.dart';
import '../../models/resource_documents.dart';
import '../theme/codex_typography.dart';
import '../theme/motif_theme.dart';
import '../widgets/codex_motion.dart';
import 'git_diff_panel.dart';
import 'preview_pane.dart';

class CodexFilePreviewScreen extends StatefulWidget {
  const CodexFilePreviewScreen({
    required this.state,
    required this.path,
    this.image = false,
    super.key,
  });

  final CodexConversationState state;
  final String path;
  final bool image;

  @override
  State<CodexFilePreviewScreen> createState() => _CodexFilePreviewScreenState();
}

class _CodexFilePreviewScreenState extends State<CodexFilePreviewScreen> {
  FilePreviewDocument? _document;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await widget.state.readRemoteFile(
        widget.path,
        refresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _document = FilePreviewDocument(
          path: widget.path,
          bytes: bytes,
          binary: !widget.image && _looksBinary(bytes),
          image: widget.image || _hasImageExtension(widget.path),
        );
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final document = _document;
    final content = _loading
        ? const Center(
            key: ValueKey('codex-file-loading'),
            child: CircularProgressIndicator(),
          )
        : _error != null
        ? Center(
            key: const ValueKey('codex-file-error'),
            child: Padding(
              padding: const EdgeInsets.all(MotifSpacing.lg),
              child: Text(
                'Could not read ${widget.path}: $_error',
                textAlign: TextAlign.center,
                style: CodexType.body.copyWith(color: c.danger),
              ),
            ),
          )
        : FilePreviewBody(
            key: ValueKey('codex-file-content-${document!.path}'),
            document: document,
          );
    return Scaffold(
      key: const ValueKey('codex-file-preview-screen'),
      backgroundColor: c.surface,
      appBar: AppBar(
        surfaceTintColor: Colors.transparent,
        title: Text(
          _leaf(widget.path),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const ValueKey('codex-file-refresh'),
            tooltip: 'Refresh file',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(refresh: true),
          ),
        ],
      ),
      body: CodexMotionSwitcher(child: content),
    );
  }
}

class CodexTurnDiffScreen extends StatefulWidget {
  const CodexTurnDiffScreen({
    required this.document,
    required this.onOpenFile,
    this.initialPath,
    super.key,
  });

  final DiffDocument document;
  final String? initialPath;
  final CodexOpenFile onOpenFile;

  @override
  State<CodexTurnDiffScreen> createState() => _CodexTurnDiffScreenState();
}

class _CodexTurnDiffScreenState extends State<CodexTurnDiffScreen> {
  static const double _sidebarBreakpoint = 720;
  static const double _sidebarWidth = 320;

  late String? _selectedPath;

  @override
  void initState() {
    super.initState();
    _selectedPath = _resolvedInitialPath();
  }

  @override
  void didUpdateWidget(covariant CodexTurnDiffScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document ||
        oldWidget.initialPath != widget.initialPath) {
      _selectedPath = _resolvedInitialPath();
    }
  }

  String? _resolvedInitialPath() {
    final initialPath = widget.initialPath;
    if (initialPath != null &&
        widget.document.files.any((file) => file.path == initialPath)) {
      return initialPath;
    }
    return widget.document.files.firstOrNull?.path;
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < _sidebarBreakpoint;
    return Scaffold(
      key: const ValueKey('codex-turn-diff-screen'),
      appBar: AppBar(
        title: const Text('Turn changes'),
        actions: [
          if (narrow && widget.document.files.isNotEmpty)
            Builder(
              builder: (context) => IconButton(
                key: const ValueKey('codex-turn-diff-files'),
                tooltip: 'Changed files',
                icon: const Icon(Icons.view_sidebar_outlined),
                onPressed: () => Scaffold.of(context).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: narrow && widget.document.files.isNotEmpty
          ? Drawer(
              child: SafeArea(
                child: _fileSidebar(
                  onSelected: (path) {
                    Navigator.of(context).pop();
                    _selectPath(path);
                  },
                ),
              ),
            )
          : null,
      body: narrow
          ? _diffDocument()
          : Row(
              children: [
                Expanded(child: _diffDocument()),
                SizedBox(width: _sidebarWidth, child: _fileSidebar()),
              ],
            ),
    );
  }

  Widget _diffDocument() => CodexMotionSwitcher(
    offset: Offset.zero,
    child: DiffDocumentView(
      key: ValueKey('codex-turn-diff-document-${_selectedPath ?? 'all'}'),
      document: widget.document,
      initialPath: _selectedPath,
      onOpenFile: (path) {
        final result = widget.onOpenFile(path);
        if (result is Future<void>) unawaited(result);
      },
    ),
  );

  Widget _fileSidebar({ValueChanged<String>? onSelected}) {
    final c = context.motif;
    final summary = widget.document.summary;
    return DecoratedBox(
      key: const ValueKey('codex-turn-diff-sidebar'),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(left: BorderSide(color: c.border)),
      ),
      child: DiffFileSidebar(
        summary: summary,
        selectedPath: _selectedPath,
        onOpenFile: onSelected ?? _selectPath,
      ),
    );
  }

  void _selectPath(String path) {
    if (_selectedPath == path) return;
    setState(() => _selectedPath = path);
  }
}

class CodexNetworkImageScreen extends StatelessWidget {
  const CodexNetworkImageScreen({required this.url, super.key});

  final String url;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final uri = Uri.tryParse(url);
    final data = uri?.data;
    final image = data != null
        ? Image.memory(
            data.contentAsBytes(),
            frameBuilder: _fadeImageFrame,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          )
        : Image.network(
            url,
            frameBuilder: _fadeImageFrame,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          );
    return Scaffold(
      key: const ValueKey('codex-network-image-screen'),
      backgroundColor: c.surface,
      appBar: AppBar(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('Image'),
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 8,
        child: Center(child: image),
      ),
    );
  }
}

Widget _fadeImageFrame(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSynchronouslyLoaded,
) {
  if (wasSynchronouslyLoaded) return child;
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: codexMotionDuration(context, CodexMotion.enter),
    curve: CodexMotion.enterCurve,
    child: child,
  );
}

bool _looksBinary(Uint8List bytes) {
  final sampleLength = math.min(bytes.length, 8192);
  for (var index = 0; index < sampleLength; index++) {
    if (bytes[index] == 0) return true;
  }
  return false;
}

bool _hasImageExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return const {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
  }.contains(path.substring(dot + 1).toLowerCase());
}

String _leaf(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}
