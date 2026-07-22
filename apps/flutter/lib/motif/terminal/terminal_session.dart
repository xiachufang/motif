import 'dart:typed_data';

typedef PtyByteSink = void Function(Uint8List bytes);

enum TerminalKeyAction { release, press, repeat }

extension TerminalKeyActionEncoding on TerminalKeyAction {
  int get ghosttyValue => switch (this) {
    TerminalKeyAction.release => 0,
    TerminalKeyAction.press => 1,
    TerminalKeyAction.repeat => 2,
  };
}

class TerminalKeyModifiers {
  const TerminalKeyModifiers({
    this.shift = false,
    this.ctrl = false,
    this.alt = false,
    this.meta = false,
  });

  final bool shift;
  final bool ctrl;
  final bool alt;
  final bool meta;

  int get ghosttyMask =>
      (shift ? 1 : 0) |
      (ctrl ? 1 << 1 : 0) |
      (alt ? 1 << 2 : 0) |
      (meta ? 1 << 3 : 0);
}

sealed class TerminalInputEvent {
  const TerminalInputEvent();
}

final class TerminalKeyInput extends TerminalInputEvent {
  const TerminalKeyInput({
    required this.keyId,
    required this.action,
    this.modifiers = const TerminalKeyModifiers(),
  });

  final String keyId;
  final TerminalKeyAction action;
  final TerminalKeyModifiers modifiers;

  TerminalKeyInput copyWith({TerminalKeyAction? action}) => TerminalKeyInput(
    keyId: keyId,
    action: action ?? this.action,
    modifiers: modifiers,
  );
}

final class TerminalPasteInput extends TerminalInputEvent {
  TerminalPasteInput(List<int> bytes) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
}

typedef TerminalInputSink = bool Function(TerminalInputEvent event);

/// The narrow host contract required by a terminal surface.
abstract interface class TerminalSession {
  bool get canInput;

  void registerPtySink(String ptyId, PtyByteSink sink);
  void unregisterPtySink(String ptyId, [PtyByteSink? sink]);
  void registerTerminalInputSink(String ptyId, TerminalInputSink sink);
  void unregisterTerminalInputSink(String ptyId, [TerminalInputSink? sink]);
  bool dispatchTerminalInput(String ptyId, TerminalInputEvent event);
  Future<void> writePty(String ptyId, List<int> data);
  Future<void> resizePty(String ptyId, int cols, int rows);
  Future<void> activatePtyStream(String ptyId);
  Future<void> deactivatePtyStream(String ptyId);
  Future<void> resyncPtyStream(String ptyId, {required String reason});
}
