import 'dart:typed_data';

typedef PtyByteSink = void Function(Uint8List bytes);

/// The narrow host contract required by a terminal surface.
abstract interface class TerminalSession {
  bool get canInput;

  void registerPtySink(String ptyId, PtyByteSink sink);
  void unregisterPtySink(String ptyId, [PtyByteSink? sink]);
  Future<void> writePty(String ptyId, List<int> data);
  Future<void> resizePty(String ptyId, int cols, int rows);
  Future<void> activatePtyStream(String ptyId);
  Future<void> deactivatePtyStream(String ptyId);
}
