import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
      body: WebViewWidget(controller: _controller),
    );
  }
}
