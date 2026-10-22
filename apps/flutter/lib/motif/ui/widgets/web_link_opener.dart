import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../log/log.dart';
import '../../net/web_link.dart';
import '../screens/remote_port_webview_screen.dart';
import 'top_toast.dart';

/// Supplies the originating server even when multiple workspaces stay mounted.
class WebLinkScope extends InheritedTheme {
  const WebLinkScope({
    required this.openProxy,
    required super.child,
    super.key,
  });

  final WebLinkProxyFactory? openProxy;

  static WebLinkScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<WebLinkScope>();

  @override
  Widget wrap(BuildContext context, Widget child) =>
      WebLinkScope(openProxy: openProxy, child: child);

  @override
  bool updateShouldNotify(WebLinkScope oldWidget) =>
      openProxy != oldWidget.openProxy;
}

bool get supportsInAppWebView =>
    !kIsWeb &&
    const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);

/// Shared click handler for terminal and Markdown web links. File navigation
/// stays with the feature that owns the remote file preview.
Future<bool> openWebLink(BuildContext context, String value) async {
  final uri = parseWebLink(value);
  if (uri == null) {
    if (context.mounted) showMotifToast(context, 'Could not open this link.');
    return false;
  }
  WebLinkProxy? proxy;
  try {
    var destination = uri;
    if (webLinkNeedsServerProxy(uri)) {
      final openProxy = WebLinkScope.maybeOf(context)?.openProxy;
      if (!supportsInAppWebView || openProxy == null) {
        throw UnsupportedError('Server browser is unavailable here');
      }
      proxy = await openProxy(uri);
      destination = proxy.url;
    }
    if (!context.mounted) return false;
    if (!supportsInAppWebView) {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) throw StateError('Could not open the browser');
      return true;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => RemotePortWebViewScreen(
          initialUrl: destination,
          title: uri.authority,
        ),
      ),
    );
    return true;
  } catch (_) {
    if (context.mounted) showMotifToast(context, 'Could not open this link.');
    return false;
  } finally {
    try {
      await proxy?.close();
    } catch (error, stackTrace) {
      Log.w(
        'Could not close browser proxy',
        name: 'motif.port',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
