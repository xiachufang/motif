import 'dart:typed_data';

import 'shell_integration.dart';

class ProcessedPtyFrame {
  final Uint8List passthrough;
  final List<ShellEvent> events;
  final String? blockId;
  final ShellOutputScope scope;
  final int decodedLength;

  const ProcessedPtyFrame({
    required this.passthrough,
    required this.events,
    required this.blockId,
    required this.scope,
    required this.decodedLength,
  });
}
