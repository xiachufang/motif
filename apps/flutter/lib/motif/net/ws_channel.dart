/// Cross-platform WebSocket connector.
///
/// Native platforms use `IOWebSocketChannel`, which can set the
/// `Authorization` header on the upgrade request (what motifd expects). The web
/// browser WebSocket API cannot set request headers, so the web implementation
/// ignores them — auth must travel in the query string there (server support
/// required; see MOTIF_FLUTTER_PLAN.md web phase).
library;

export 'ws_channel_io.dart' if (dart.library.html) 'ws_channel_web.dart';
