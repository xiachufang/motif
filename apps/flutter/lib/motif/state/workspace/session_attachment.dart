import 'connection/workspace_connection_view_model.dart';

/// Session attachment lifecycle exposed to workspace UI/coordinators.
abstract interface class SessionAttachment {
  String get session;
  WorkspaceConnectionViewModel get connection;
  bool get isLive;

  Future<void> attach();
  Future<void> detach();
  void setForeground(bool foreground);
  void setTerminalPalette({String? fg, String? bg, String? theme});
}
