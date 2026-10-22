import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/motif/net/web_link.dart';
import 'package:motif/motif/ui/screens/remote_port_webview_screen.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/codex_markdown.dart';
import 'package:motif/motif/ui/widgets/web_link_opener.dart';
// Test implementation of the platform interface behind webview_flutter.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  late _BrowserPlatform browser;
  setUp(() {
    browser = _BrowserPlatform();
    WebViewPlatform.instance = browser;
  });

  for (final markdown in [false, true]) {
    for (final url in [
      'https://example.com/docs?q=1#section',
      'http://127.0.0.1:3000/docs?q=1#section',
    ]) {
      testWidgets(
        'opens $url via ${markdown ? 'Markdown' : 'shared handler'}',
        (tester) async {
          final proxied = <Uri>[];
          var closed = 0;
          final local = Uri.parse('http://127.0.0.1:49152/');
          await tester.pumpWidget(
            MaterialApp(
              theme: motifTheme(Brightness.light),
              home: WebLinkScope(
                openProxy: (uri) async {
                  proxied.add(uri);
                  return WebLinkProxy(
                    url: proxiedWebLink(uri, local),
                    close: () async => closed++,
                  );
                },
                child: Builder(
                  builder: (context) => Scaffold(
                    body: markdown
                        ? CodexMarkdown('[Open page]($url)')
                        : TextButton(
                            onPressed: () =>
                                unawaited(openWebLink(context, url)),
                            child: const Text('Open page'),
                          ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open page'));
          await tester.pumpAndSettle();
          final needsProxy = webLinkNeedsServerProxy(Uri.parse(url));
          expect(proxied, needsProxy ? [Uri.parse(url)] : isEmpty);
          expect(find.byType(RemotePortWebViewScreen), findsOneWidget);
          expect(
            browser.loaded.single,
            needsProxy ? proxiedWebLink(Uri.parse(url), local) : Uri.parse(url),
          );
          expect(closed, 0);
          await tester.tap(find.byTooltip('Close'));
          await tester.pumpAndSettle();
          expect(find.byType(RemotePortWebViewScreen), findsNothing);
          expect(closed, needsProxy ? 1 : 0);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }

  testWidgets('a failed server proxy never opens the IP directly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: WebLinkScope(
          openProxy: (_) async => throw StateError('server unavailable'),
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    unawaited(openWebLink(context, 'http://127.0.0.1:3000')),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(browser.loaded, isEmpty);
    expect(find.text('Could not open this link.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Markdown file links retain their internal preview callback', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: CodexMarkdown(
            '[File](/tmp/main.dart:12)',
            onTapFileLink: (href) => opened = href,
          ),
        ),
      ),
    );
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(opened, '/tmp/main.dart:12');
    expect(browser.loaded, isEmpty);
  });

  testWidgets(
    'releases proxy if the originating page disappears while opening',
    (tester) async {
      final pending = Completer<WebLinkProxy>();
      var closed = false;
      Future<bool>? opening;
      await tester.pumpWidget(
        MaterialApp(
          home: WebLinkScope(
            openProxy: (_) => pending.future,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    opening = openWebLink(context, 'http://localhost:3000'),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpWidget(const SizedBox());
      pending.complete(
        WebLinkProxy(
          url: Uri.parse('http://127.0.0.1:49152'),
          close: () async => closed = true,
        ),
      );
      await tester.pump();
      expect(await opening, isFalse);
      expect(closed, isTrue);
      expect(browser.loaded, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

class _BrowserPlatform extends WebViewPlatform {
  final loaded = <Uri>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _BrowserController(params, loaded);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _NavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _BrowserWidget(params);
}

class _BrowserController extends PlatformWebViewController {
  _BrowserController(super.params, this.loaded) : super.implementation();
  final List<Uri> loaded;
  _NavigationDelegate? delegate;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => delegate = handler as _NavigationDelegate;

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loaded.add(params.uri);
    scheduleMicrotask(() => delegate?.finished?.call(params.uri.toString()));
  }

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;
}

class _NavigationDelegate extends PlatformNavigationDelegate {
  _NavigationDelegate(super.params) : super.implementation();
  PageEventCallback? finished;

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async =>
      finished = callback;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

class _BrowserWidget extends PlatformWebViewWidget {
  _BrowserWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
