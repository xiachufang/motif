import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/motif_proto.dart';
import '../../state/workspace/workspace_api.dart';
import '../theme/motif_theme.dart';

/// Pushes a target-selection page. Choosing a remote display or window pushes
/// a second, zoomable screenshot page on top of it.
Future<void> showScreenCaptureFlow(
  BuildContext context,
  WorkspaceApi workspace,
) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _CaptureTargetPicker(workspace: workspace),
    ),
  );
}

class _CaptureTargetPicker extends StatefulWidget {
  const _CaptureTargetPicker({required this.workspace});

  final WorkspaceApi workspace;

  @override
  State<_CaptureTargetPicker> createState() => _CaptureTargetPickerState();
}

class _CaptureTargetPickerState extends State<_CaptureTargetPicker> {
  CaptureTargetsResult? _targets;
  Object? _error;
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final targets = await widget.workspace.captureTargets();
      if (!mounted) return;
      setState(() {
        _targets = targets;
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
    return Scaffold(
      key: const ValueKey('capture-target-picker'),
      backgroundColor: c.background,
      appBar: AppBar(
        title: const Text('Capture screen'),
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(
            key: const ValueKey('refresh-capture-targets'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh targets',
            onPressed: _loading ? null : () => unawaited(_load()),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Future<void> _openTarget(CaptureTarget target) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            _ScreenCaptureViewer(workspace: widget.workspace, target: target),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = context.motif;
    if (_loading && _targets == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error case final error?) {
      return _CaptureMessage(
        icon: Icons.error_outline,
        iconColor: c.danger,
        title: 'Could not load capture targets',
        detail: '$error',
        action: FilledButton.icon(
          onPressed: () => unawaited(_load()),
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        ),
      );
    }

    final targets = _targets;
    if (targets == null || !targets.available) {
      return _CaptureMessage(
        icon: Icons.screenshot_monitor_outlined,
        iconColor: c.textTertiary,
        title: 'Screen capture is unavailable',
        detail:
            targets?.reason ??
            'Enable screen capture on the server and reconnect.',
      );
    }

    final query = _query.trim().toLowerCase();
    final windows = query.isEmpty
        ? targets.windows
        : targets.windows
              .where(
                (target) => [
                  target.name,
                  target.appName ?? '',
                  target.title ?? '',
                ].any((value) => value.toLowerCase().contains(query)),
              )
              .toList(growable: false);
    if (targets.displays.isEmpty && targets.windows.isEmpty) {
      return _CaptureMessage(
        icon: Icons.layers_clear_outlined,
        iconColor: c.textTertiary,
        title: 'No screens or windows found',
        detail:
            targets.reason ?? 'Check the server screen-recording permission.',
        action: FilledButton.icon(
          onPressed: () => unawaited(_load()),
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh'),
        ),
      );
    }

    return Column(
      children: [
        if (targets.reason case final reason?)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(
              MotifSpacing.lg,
              MotifSpacing.sm,
              MotifSpacing.lg,
              0,
            ),
            padding: const EdgeInsets.all(MotifSpacing.md),
            decoration: BoxDecoration(
              color: c.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(MotifRadius.xs),
            ),
            child: Text(
              reason,
              style: MotifType.subhead.copyWith(color: c.textSecondary),
            ),
          ),
        if (targets.windows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MotifSpacing.lg,
              MotifSpacing.md,
              MotifSpacing.lg,
              MotifSpacing.xs,
            ),
            child: TextField(
              key: const ValueKey('capture-window-search'),
              decoration: const InputDecoration(
                hintText: 'Search windows',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
        Expanded(
          child: ListView(
            primary: true,
            padding: const EdgeInsets.only(bottom: MotifSpacing.lg),
            children: [
              if (targets.displays.isNotEmpty) ...[
                const _CaptureSectionLabel('Displays'),
                for (final target in targets.displays)
                  _CaptureTargetTile(
                    target: target,
                    onTap: () => unawaited(_openTarget(target)),
                  ),
              ],
              if (targets.windows.isNotEmpty) ...[
                const _CaptureSectionLabel('Windows'),
                if (windows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(MotifSpacing.xl),
                    child: Text(
                      'No windows match your search.',
                      textAlign: TextAlign.center,
                      style: MotifType.body.copyWith(color: c.textTertiary),
                    ),
                  )
                else
                  for (final target in windows)
                    _CaptureTargetTile(
                      target: target,
                      onTap: () => unawaited(_openTarget(target)),
                    ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CaptureSectionLabel extends StatelessWidget {
  const _CaptureSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MotifSpacing.lg,
        MotifSpacing.lg,
        MotifSpacing.lg,
        MotifSpacing.xs,
      ),
      child: Text(
        label.toUpperCase(),
        style: MotifType.overline.copyWith(color: context.motif.textTertiary),
      ),
    );
  }
}

class _CaptureTargetTile extends StatelessWidget {
  const _CaptureTargetTile({required this.target, required this.onTap});

  final CaptureTarget target;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final badge = target.primary
        ? 'Primary'
        : target.focused
        ? 'Focused'
        : null;
    final dimensions = target.width > 0 && target.height > 0
        ? '${target.width} × ${target.height}'
        : null;
    final isWindow = target.kind == CaptureTargetKind.window;
    final subtitleParts = isWindow
        ? <String>[?target.title]
        : <String>[?dimensions, ?badge];
    return ListTile(
      key: ValueKey('capture-target-${target.kind.name}-${target.id}'),
      leading: isWindow
          ? _AppIcon(target: target)
          : const Icon(Icons.monitor_outlined),
      title: Text(
        isWindow ? target.appName ?? target.name : target.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitleParts.isEmpty
          ? isWindow
                ? Text(
                    'Untitled window',
                    style: TextStyle(color: c.textTertiary),
                  )
                : null
          : Text(
              subtitleParts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.target});

  final CaptureTarget target;

  @override
  Widget build(BuildContext context) {
    final bytes = target.appIconPng;
    if (bytes == null || bytes.isEmpty) return _fallback(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(MotifRadius.xs),
      child: Image.memory(
        bytes,
        key: ValueKey('capture-app-icon-${target.appName}'),
        width: 36,
        height: 36,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _fallback(context),
      ),
    );
  }

  Widget _fallback(BuildContext context) {
    final c = context.motif;
    final appName = target.appName?.trim() ?? '';
    final initial = appName.isEmpty
        ? '?'
        : appName.characters.first.toUpperCase();
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.accentFill(),
        borderRadius: BorderRadius.circular(MotifRadius.xs),
      ),
      child: Text(initial, style: MotifType.headline.copyWith(color: c.accent)),
    );
  }
}

class _CaptureMessage extends StatelessWidget {
  const _CaptureMessage({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MotifSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: iconColor),
            const SizedBox(height: MotifSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: MotifType.headline.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: MotifSpacing.xs),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: MotifType.subhead.copyWith(color: c.textTertiary),
            ),
            if (action != null) ...[
              const SizedBox(height: MotifSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _ScreenCaptureViewer extends StatefulWidget {
  const _ScreenCaptureViewer({required this.workspace, required this.target});

  final WorkspaceApi workspace;
  final CaptureTarget target;

  @override
  State<_ScreenCaptureViewer> createState() => _ScreenCaptureViewerState();
}

class _ScreenCaptureViewerState extends State<_ScreenCaptureViewer> {
  Uint8List? _image;
  Object? _error;
  bool _loading = true;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_capture());
  }

  Future<void> _capture() async {
    final generation = ++_requestGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final image = await widget.workspace.capture(widget.target);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _image = image;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Scaffold(
      key: const ValueKey('screen-capture-viewer'),
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.target.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(
            key: const ValueKey('retake-screen-capture'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Capture again',
            onPressed: _loading ? null : () => unawaited(_capture()),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_image case final image?)
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 8,
              boundaryMargin: const EdgeInsets.all(80),
              child: Center(
                child: Image.memory(
                  image,
                  key: const ValueKey('screen-capture-image'),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, _) => _CaptureMessage(
                    icon: Icons.broken_image_outlined,
                    iconColor: c.danger,
                    title: 'Could not display screenshot',
                    detail: '$error',
                  ),
                ),
              ),
            ),
          if (_error case final error?)
            ColoredBox(
              color: c.background,
              child: _CaptureMessage(
                icon: Icons.error_outline,
                iconColor: c.danger,
                title: 'Screenshot failed',
                detail: '$error',
                action: FilledButton.icon(
                  onPressed: () => unawaited(_capture()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ),
            ),
          if (_loading)
            ColoredBox(
              color: Colors.black.withValues(alpha: _image == null ? 1 : 0.5),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
