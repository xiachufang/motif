import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

const double _mobileHistoryEdgeWidth = 28;
const double _mobileHistorySwipeDistance = 64;
const double _mobileHistorySwipeVelocity = 520;
const double _desktopHistoryScrollThreshold = 90;
const Duration _historyGestureCooldown = Duration(milliseconds: 550);

enum _HistoryDirection { back, forward }

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

  Widget _buildWebViewBody() {
    final webView = Listener(
      onPointerSignal: _handlePointerSignal,
      child: WebViewWidget(controller: _controller),
    );
    if (!_usesMobileEdgeHistoryGesture) return webView;

    return Stack(
      children: [
        Positioned.fill(child: webView),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _mobileHistoryEdgeWidth,
          child: _HistorySwipeEdge(
            direction: _HistoryDirection.back,
            enabled: _canGoBack,
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
            onTriggered: () => _navigateHistory(_HistoryDirection.forward),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: _allowClose,
      child: Scaffold(
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
      ),
    );
  }
}

class _HistorySwipeEdge extends StatefulWidget {
  const _HistorySwipeEdge({
    required this.direction,
    required this.enabled,
    required this.onTriggered,
  });

  final _HistoryDirection direction;
  final bool enabled;
  final Future<void> Function() onTriggered;

  @override
  State<_HistorySwipeEdge> createState() => _HistorySwipeEdgeState();
}

class _HistorySwipeEdgeState extends State<_HistorySwipeEdge> {
  double _dragDx = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: widget.enabled ? (_) => _dragDx = 0 : null,
      onHorizontalDragUpdate: widget.enabled
          ? (details) => _dragDx += details.delta.dx
          : null,
      onHorizontalDragCancel: widget.enabled ? () => _dragDx = 0 : null,
      onHorizontalDragEnd: widget.enabled
          ? (details) {
              final velocity = details.primaryVelocity ?? 0;
              final back = widget.direction == _HistoryDirection.back;
              final distanceTriggered = back
                  ? _dragDx >= _mobileHistorySwipeDistance
                  : _dragDx <= -_mobileHistorySwipeDistance;
              final velocityTriggered = back
                  ? velocity >= _mobileHistorySwipeVelocity
                  : velocity <= -_mobileHistorySwipeVelocity;
              _dragDx = 0;
              if (distanceTriggered || velocityTriggered) {
                unawaited(widget.onTriggered());
              }
            }
          : null,
    );
  }
}
