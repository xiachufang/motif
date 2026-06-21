import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../platform/desktop_window.dart';
import '../theme/motif_theme.dart';

const double _desktopTitleBarHeight = 38;
const double _mobileHistoryEdgeWidth = 28;
const double _mobileHistorySwipeDistance = 64;
const double _mobileHistorySwipeVelocity = 520;
const double _historyGestureIndicatorSize = 52;
const double _historyGestureIndicatorRestingInset = 18;
const double _desktopHistoryScrollThreshold = 90;
const Duration _historyGestureSettleDuration = Duration(milliseconds: 160);
const Duration _historyGestureCommitDuration = Duration(milliseconds: 220);
const Duration _historyGestureCooldown = Duration(milliseconds: 550);

enum _HistoryDirection { back, forward }

class _HistoryGestureFeedback {
  const _HistoryGestureFeedback({
    required this.direction,
    required this.progress,
    required this.active,
    this.committed = false,
  });

  final _HistoryDirection direction;
  final double progress;
  final bool active;
  final bool committed;
}

class RemotePortWebViewScreen extends StatefulWidget {
  const RemotePortWebViewScreen({
    super.key,
    required this.initialUrl,
    required this.title,
    this.onClose,
  });

  final Uri initialUrl;
  final String title;
  final Future<void> Function()? onClose;

  @override
  State<RemotePortWebViewScreen> createState() =>
      _RemotePortWebViewScreenState();
}

class _RemotePortWebViewScreenState extends State<RemotePortWebViewScreen> {
  late final WebViewController _controller;
  String _url = '';
  bool _loading = true;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _allowClose = false;
  double _desktopHistoryScrollDx = 0;
  DateTime? _lastHistoryGestureAt;
  _HistoryGestureFeedback? _historyGestureFeedback;
  Timer? _historyGestureClearTimer;
  int _historyGestureGeneration = 0;

  @override
  void initState() {
    super.initState();
    _url = widget.initialUrl.toString();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _url = url;
              _loading = true;
            });
            unawaited(_refreshNavigationState());
          },
          onPageFinished: (url) {
            setState(() {
              _url = url;
              _loading = false;
            });
            unawaited(_refreshNavigationState());
          },
          onWebResourceError: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      )
      ..loadRequest(widget.initialUrl);
    _enablePlatformHistoryGestures();
  }

  @override
  void dispose() {
    _historyGestureClearTimer?.cancel();
    final onClose = widget.onClose;
    if (onClose != null) unawaited(onClose());
    super.dispose();
  }

  Future<void> _refreshNavigationState() async {
    final canGoBack = await _controller.canGoBack();
    final canGoForward = await _controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = canGoBack;
      _canGoForward = canGoForward;
    });
  }

  void _close() {
    setState(() => _allowClose = true);
    Navigator.of(context).pop();
  }

  void _enablePlatformHistoryGestures() {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.macOS)) {
      return;
    }
    final platformController = _controller.platform as dynamic;
    unawaited(
      platformController
          .setAllowsBackForwardNavigationGestures(true)
          .catchError((_) {}),
    );
  }

  bool get _usesDesktopHistoryGesture {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  bool get _usesMobileEdgeHistoryGesture {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!_usesDesktopHistoryGesture || event is! PointerScrollEvent) return;
    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy;
    if (dx.abs() < 8 || dx.abs() < dy.abs() * 1.2) return;

    _desktopHistoryScrollDx += dx;
    if (_desktopHistoryScrollDx <= -_desktopHistoryScrollThreshold) {
      _desktopHistoryScrollDx = 0;
      unawaited(_navigateHistory(_HistoryDirection.back));
    } else if (_desktopHistoryScrollDx >= _desktopHistoryScrollThreshold) {
      _desktopHistoryScrollDx = 0;
      unawaited(_navigateHistory(_HistoryDirection.forward));
    }
  }

  Future<void> _navigateHistory(_HistoryDirection direction) async {
    final now = DateTime.now();
    final last = _lastHistoryGestureAt;
    if (last != null && now.difference(last) < _historyGestureCooldown) {
      return;
    }

    final canNavigate = direction == _HistoryDirection.back
        ? await _controller.canGoBack()
        : await _controller.canGoForward();
    if (!canNavigate) return;

    _lastHistoryGestureAt = now;
    if (direction == _HistoryDirection.back) {
      await _controller.goBack();
    } else {
      await _controller.goForward();
    }
    await _refreshNavigationState();
  }

  void _showHistoryGestureFeedback(_HistoryGestureFeedback feedback) {
    _historyGestureClearTimer?.cancel();
    final generation = ++_historyGestureGeneration;
    if (!mounted) return;
    setState(() => _historyGestureFeedback = feedback);

    if (feedback.active) return;

    _historyGestureClearTimer = Timer(
      feedback.committed
          ? _historyGestureCommitDuration
          : _historyGestureSettleDuration,
      () {
        if (!mounted || _historyGestureGeneration != generation) return;
        setState(() => _historyGestureFeedback = null);
      },
    );
  }

  Widget _buildWebViewBody() {
    final webView = Listener(
      onPointerSignal: _handlePointerSignal,
      child: WebViewWidget(controller: _controller),
    );
    if (!_usesMobileEdgeHistoryGesture) return webView;

    return Stack(
      children: [
        Positioned.fill(child: webView),
        Positioned.fill(
          child: IgnorePointer(
            child: _HistoryGestureOverlay(feedback: _historyGestureFeedback),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _mobileHistoryEdgeWidth,
          child: _HistorySwipeEdge(
            direction: _HistoryDirection.back,
            enabled: _canGoBack,
            onFeedback: _showHistoryGestureFeedback,
            onTriggered: () => _navigateHistory(_HistoryDirection.back),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: _mobileHistoryEdgeWidth,
          child: _HistorySwipeEdge(
            direction: _HistoryDirection.forward,
            enabled: _canGoForward,
            onFeedback: _showHistoryGestureFeedback,
            onTriggered: () => _navigateHistory(_HistoryDirection.forward),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: _close,
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, overflow: TextOverflow.ellipsis),
            Text(
              _url,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: _canGoBack
                ? () async {
                    await _controller.goBack();
                    await _refreshNavigationState();
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            tooltip: 'Forward',
            onPressed: _canGoForward
                ? () async {
                    await _controller.goForward();
                    await _refreshNavigationState();
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: () => _controller.reload(),
          ),
        ],
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: _buildWebViewBody(),
    );

    return PopScope<void>(
      canPop: _allowClose,
      child: _DesktopTitleBarPadding(child: scaffold),
    );
  }
}

class _DesktopTitleBarPadding extends StatelessWidget {
  const _DesktopTitleBarPadding({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!DesktopWindow.usesCustomTitleBar) return child;
    final c = context.motif;
    return Column(
      children: [
        Material(
          color: c.surface,
          child: Container(
            height: _desktopTitleBarHeight,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => DesktopWindow.startDrag(),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _HistorySwipeEdge extends StatefulWidget {
  const _HistorySwipeEdge({
    required this.direction,
    required this.enabled,
    required this.onFeedback,
    required this.onTriggered,
  });

  final _HistoryDirection direction;
  final bool enabled;
  final ValueChanged<_HistoryGestureFeedback> onFeedback;
  final Future<void> Function() onTriggered;

  @override
  State<_HistorySwipeEdge> createState() => _HistorySwipeEdgeState();
}

class _HistorySwipeEdgeState extends State<_HistorySwipeEdge> {
  double _dragDx = 0;
  bool _dragActive = false;

  @override
  void didUpdateWidget(covariant _HistorySwipeEdge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled && _dragActive) {
      _cancelGesture();
    }
  }

  bool get _isBackGesture => widget.direction == _HistoryDirection.back;

  double get _progress {
    final intendedDx = _isBackGesture ? _dragDx : -_dragDx;
    return (intendedDx / _mobileHistorySwipeDistance).clamp(0.0, 1.0);
  }

  void _emitGestureFeedback({
    required double progress,
    required bool active,
    bool committed = false,
  }) {
    widget.onFeedback(
      _HistoryGestureFeedback(
        direction: widget.direction,
        progress: progress,
        active: active,
        committed: committed,
      ),
    );
  }

  void _cancelGesture() {
    _dragActive = false;
    _dragDx = 0;
    _emitGestureFeedback(progress: 0, active: false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: widget.enabled
          ? (details) {
              _dragActive = true;
              _dragDx = 0;
              _emitGestureFeedback(progress: 0, active: true);
            }
          : null,
      onHorizontalDragUpdate: widget.enabled
          ? (details) {
              _dragDx += details.delta.dx;
              _emitGestureFeedback(progress: _progress, active: true);
            }
          : null,
      onHorizontalDragCancel: widget.enabled ? _cancelGesture : null,
      onHorizontalDragEnd: widget.enabled
          ? (details) {
              final velocity = details.primaryVelocity ?? 0;
              final distanceTriggered = _isBackGesture
                  ? _dragDx >= _mobileHistorySwipeDistance
                  : _dragDx <= -_mobileHistorySwipeDistance;
              final velocityTriggered = _isBackGesture
                  ? velocity >= _mobileHistorySwipeVelocity
                  : velocity <= -_mobileHistorySwipeVelocity;
              _dragActive = false;
              _dragDx = 0;
              if (distanceTriggered || velocityTriggered) {
                _emitGestureFeedback(
                  progress: 1,
                  active: false,
                  committed: true,
                );
                unawaited(widget.onTriggered());
              } else {
                _emitGestureFeedback(progress: 0, active: false);
              }
            }
          : null,
    );
  }
}

class _HistoryGestureOverlay extends StatelessWidget {
  const _HistoryGestureOverlay({required this.feedback});

  final _HistoryGestureFeedback? feedback;

  @override
  Widget build(BuildContext context) {
    final feedback = this.feedback;
    if (feedback == null) return const SizedBox.shrink();

    final progress = feedback.progress.clamp(0.0, 1.0);
    final eased = Curves.easeOutCubic.transform(progress);
    final activeOpacity = (0.18 + eased * 0.82).clamp(0.0, 1.0);
    final opacity = feedback.active ? activeOpacity : 0.0;
    final inset = _lerpDouble(
      -_historyGestureIndicatorSize * 0.62,
      _historyGestureIndicatorRestingInset,
      eased,
    );
    final scale = feedback.committed ? 1.08 : _lerpDouble(0.82, 1.0, eased);
    final duration = feedback.active
        ? Duration.zero
        : _historyGestureSettleDuration;

    return LayoutBuilder(
      builder: (context, constraints) {
        final top = ((constraints.maxHeight - _historyGestureIndicatorSize) / 2)
            .clamp(0.0, double.infinity)
            .toDouble();

        return Stack(
          children: [
            AnimatedPositioned(
              duration: duration,
              curve: Curves.easeOutCubic,
              left: feedback.direction == _HistoryDirection.back ? inset : null,
              right: feedback.direction == _HistoryDirection.forward
                  ? inset
                  : null,
              top: top,
              width: _historyGestureIndicatorSize,
              height: _historyGestureIndicatorSize,
              child: AnimatedOpacity(
                duration: duration,
                curve: Curves.easeOut,
                opacity: opacity,
                child: AnimatedScale(
                  duration: duration,
                  curve: Curves.easeOutBack,
                  scale: scale,
                  child: _HistoryGestureIndicator(feedback: feedback),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HistoryGestureIndicator extends StatelessWidget {
  const _HistoryGestureIndicator({required this.feedback});

  final _HistoryGestureFeedback feedback;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progress = feedback.progress.clamp(0.0, 1.0);
    final ready = progress >= 1 || feedback.committed;
    final foreground = ready
        ? colorScheme.primary
        : colorScheme.onSurface.withValues(alpha: 0.72);

    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colorScheme.surface.withValues(alpha: 0.94),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2.5,
                  backgroundColor: colorScheme.onSurface.withValues(
                    alpha: 0.12,
                  ),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    ready
                        ? colorScheme.primary
                        : colorScheme.onSurface.withValues(alpha: 0.34),
                  ),
                ),
              ),
            ),
            Icon(
              feedback.direction == _HistoryDirection.back
                  ? Icons.arrow_back_rounded
                  : Icons.arrow_forward_rounded,
              size: 26,
              color: foreground,
            ),
          ],
        ),
      ),
    );
  }
}

double _lerpDouble(double begin, double end, double t) {
  return begin + (end - begin) * t;
}
