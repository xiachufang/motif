/// Per-PTY shell-integration parser.
///
/// Ported from `apps/ios/Motif/Native/ShellIntegration.swift` (which itself
/// mirrors the Rust parser in `crates/motif-client/src/shell_integration.rs`).
/// Consumes raw PTY bytes, strips Motif's private OSC markers, and drives a
/// block state machine emitting high-level [ShellEvent]s.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// High-level shell events emitted by the block state machine.
sealed class ShellEvent {
  const ShellEvent();
}

class ShellBootstrapped extends ShellEvent {
  final String shell;
  const ShellBootstrapped(this.shell);
}

class ShellPromptStarted extends ShellEvent {
  final String blockId;
  const ShellPromptStarted(this.blockId);
}

class ShellPromptEnded extends ShellEvent {
  final String blockId;
  const ShellPromptEnded(this.blockId);
}

class ShellCommandStarted extends ShellEvent {
  final String blockId;
  final String text;
  final String cwd;
  final int startedAt;
  const ShellCommandStarted({
    required this.blockId,
    required this.text,
    required this.cwd,
    required this.startedAt,
  });
}

class ShellCommandFinished extends ShellEvent {
  final String blockId;
  final int? exitCode;
  final int finishedAt;
  const ShellCommandFinished({
    required this.blockId,
    required this.exitCode,
    required this.finishedAt,
  });
}

class ShellContextEvent extends ShellEvent {
  final Map<String, String> ctx;
  const ShellContextEvent(this.ctx);
}

class ShellCwdChanged extends ShellEvent {
  final String cwd;
  const ShellCwdChanged(this.cwd);
}

enum ShellOutputScope {
  prompt('Prompt'),
  command('Command'),
  output('Output'),
  passthrough('Passthrough');

  final String wire;
  const ShellOutputScope(this.wire);
}

/// Result of feeding a byte chunk: passthrough bytes (markers stripped) +
/// the events emitted in arrival order.
class ShellFeedResult {
  final Uint8List passthrough;
  final List<ShellEvent> events;
  const ShellFeedResult(this.passthrough, this.events);
}

// ─────────────────────────── state machine ───────────────────────────

sealed class _Stage {
  const _Stage();
}

class _Unknown extends _Stage {
  const _Unknown();
}

class _AtPrompt extends _Stage {
  final String blockId;
  final String cwd;
  final int startedAt;
  const _AtPrompt(this.blockId, this.cwd, this.startedAt);
}

class _Composing extends _Stage {
  final String blockId;
  final String cwd;
  final int startedAt;
  const _Composing(this.blockId, this.cwd, this.startedAt);
}

class _Running extends _Stage {
  final String blockId;
  final String cmd;
  final String cwd;
  final int startedAt;
  const _Running(this.blockId, this.cmd, this.cwd, this.startedAt);
}

class ShellState {
  String? activeBlockId;
  ShellOutputScope activeScope = ShellOutputScope.passthrough;

  _Stage _stage = const _Unknown();
  String _currentCwd = '';
  String? _pendingCmd;
  bool bootstrapAnnounced = false;
  final _OscScanner _scanner = _OscScanner();
  final Random _rng = Random.secure();

  ShellFeedResult feed(Uint8List data) {
    final scan = _scanner.feed(data);
    final events = <ShellEvent>[];
    final passthrough = BytesBuilder(copy: false);
    for (final item in scan) {
      if (item is _ScanBytes) {
        passthrough.add(item.bytes);
      } else if (item is _ScanMarker) {
        events.addAll(_handle(item.marker));
      }
    }
    return ShellFeedResult(passthrough.takeBytes(), events);
  }

  /// Force-finalize any in-flight block (e.g. when the WS closes).
  ShellEvent? onClose() {
    final s = _stage;
    if (s is _Running) {
      return ShellCommandFinished(
        blockId: s.blockId,
        exitCode: null,
        finishedAt: _nowMs(),
      );
    }
    return null;
  }

  List<ShellEvent> _handle(_OscMarker m) {
    final out = <ShellEvent>[];
    if (!bootstrapAnnounced) {
      bootstrapAnnounced = true;
      out.add(const ShellBootstrapped('unknown'));
    }

    switch (m) {
      case _Osc7Cwd(:final cwd):
        if (cwd != _currentCwd) {
          _currentCwd = cwd;
          out.add(ShellCwdChanged(cwd));
        }
      case _Osc133PromptStart():
        _pendingCmd = null;
        final cwd = _currentCwd.isEmpty ? '/' : _currentCwd;
        final s = _stage;
        if (s is _AtPrompt) {
          _stage = _AtPrompt(s.blockId, s.cwd, s.startedAt);
          out.add(ShellPromptStarted(s.blockId));
        } else if (s is _Composing) {
          _stage = _AtPrompt(s.blockId, s.cwd, s.startedAt);
          out.add(ShellPromptStarted(s.blockId));
        } else if (s is _Running) {
          out.add(ShellCommandFinished(
            blockId: s.blockId,
            exitCode: null,
            finishedAt: _nowMs(),
          ));
          final newId = _ulid();
          _stage = _AtPrompt(newId, cwd, _nowMs());
          out.add(ShellPromptStarted(newId));
        } else {
          final newId = _ulid();
          _stage = _AtPrompt(newId, cwd, _nowMs());
          out.add(ShellPromptStarted(newId));
        }
      case _Osc133PromptEnd():
        final s = _stage;
        if (s is _AtPrompt) {
          out.add(ShellPromptEnded(s.blockId));
          _stage = _Composing(s.blockId, s.cwd, s.startedAt);
        }
      case _Osc7770Cmd(:final text):
        _pendingCmd = text;
      case _Osc133CmdStart(:final cmdlineUrl):
        final s = _stage;
        if (s is _Composing) {
          final cmd = cmdlineUrl ?? _pendingCmd ?? '';
          _pendingCmd = null;
          final startedAt = _nowMs();
          _stage = _Running(s.blockId, cmd, s.cwd, startedAt);
          out.add(ShellCommandStarted(
            blockId: s.blockId,
            text: cmd,
            cwd: s.cwd,
            startedAt: startedAt,
          ));
        }
      case _Osc133CmdEnd(:final exit):
        _pendingCmd = null;
        final s = _stage;
        if (s is _Running) {
          out.add(ShellCommandFinished(
            blockId: s.blockId,
            exitCode: exit,
            finishedAt: _nowMs(),
          ));
          _stage = const _Unknown();
        }
      case _Osc7771Context(:final ctx):
        out.add(ShellContextEvent(ctx));
    }

    final s = _stage;
    switch (s) {
      case _Unknown():
        activeBlockId = null;
        activeScope = ShellOutputScope.passthrough;
      case _AtPrompt():
        activeBlockId = s.blockId;
        activeScope = ShellOutputScope.prompt;
      case _Composing():
        activeBlockId = s.blockId;
        activeScope = ShellOutputScope.command;
      case _Running():
        activeBlockId = s.blockId;
        activeScope = ShellOutputScope.output;
    }
    return out;
  }

  String _ulid() {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      final b = _rng.nextInt(256);
      sb.write(alphabet[b & 0x1f]);
      sb.write(alphabet[(b >> 5) & 0x1f]);
    }
    return sb.toString().substring(0, 26);
  }
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

// ─────────────────────────── scanner ───────────────────────────

sealed class _ScanItem {
  const _ScanItem();
}

class _ScanBytes extends _ScanItem {
  final Uint8List bytes;
  const _ScanBytes(this.bytes);
}

class _ScanMarker extends _ScanItem {
  final _OscMarker marker;
  const _ScanMarker(this.marker);
}

sealed class _OscMarker {
  const _OscMarker();
}

class _Osc7Cwd extends _OscMarker {
  final String cwd;
  const _Osc7Cwd(this.cwd);
}

class _Osc133PromptStart extends _OscMarker {
  const _Osc133PromptStart();
}

class _Osc133PromptEnd extends _OscMarker {
  const _Osc133PromptEnd();
}

class _Osc133CmdStart extends _OscMarker {
  final String? cmdlineUrl;
  const _Osc133CmdStart(this.cmdlineUrl);
}

class _Osc133CmdEnd extends _OscMarker {
  final int? exit;
  const _Osc133CmdEnd(this.exit);
}

class _Osc7770Cmd extends _OscMarker {
  final String text;
  const _Osc7770Cmd(this.text);
}

class _Osc7771Context extends _OscMarker {
  final Map<String, String> ctx;
  const _Osc7771Context(this.ctx);
}

/// Minimal OSC scanner: `ESC ] payload (BEL | ESC \)`. Anything unrecognized
/// passes through verbatim.
class _OscScanner {
  final List<int> _pending = [];
  bool _inOsc = false;

  List<_ScanItem> feed(Uint8List data) {
    final items = <_ScanItem>[];
    for (final b in data) {
      _step(b, items);
    }
    return items;
  }

  void _step(int b, List<_ScanItem> items) {
    if (!_inOsc) {
      if (b == 0x1b) {
        _pending
          ..clear()
          ..add(b);
        _inOsc = true;
      } else {
        _appendPassthrough(b, items);
      }
      return;
    }
    _pending.add(b);
    if (_pending.length == 2) {
      if (_pending[1] != 0x5d /* ']' */) {
        for (final byte in _pending) {
          _appendPassthrough(byte, items);
        }
        _pending.clear();
        _inOsc = false;
      }
      return;
    }
    final isBel = b == 0x07;
    final isSt =
        _pending.length >= 3 && _pending[_pending.length - 2] == 0x1b && b == 0x5c;
    if (!isBel && !isSt) {
      if (_pending.length > 4096) {
        for (final byte in _pending) {
          _appendPassthrough(byte, items);
        }
        _pending.clear();
        _inOsc = false;
      }
      return;
    }
    final bodyEnd = isSt ? _pending.length - 2 : _pending.length - 1;
    final body = _pending.sublist(2, bodyEnd);
    final marker = _parseOscBody(body);
    if (marker != null) {
      items.add(_ScanMarker(marker));
    } else {
      for (final byte in _pending) {
        _appendPassthrough(byte, items);
      }
    }
    _pending.clear();
    _inOsc = false;
  }

  void _appendPassthrough(int b, List<_ScanItem> items) {
    if (items.isNotEmpty && items.last is _ScanBytes) {
      final last = items.last as _ScanBytes;
      final merged = Uint8List(last.bytes.length + 1)
        ..setRange(0, last.bytes.length, last.bytes)
        ..[last.bytes.length] = b;
      items[items.length - 1] = _ScanBytes(merged);
    } else {
      items.add(_ScanBytes(Uint8List.fromList([b])));
    }
  }
}

_OscMarker? _parseOscBody(List<int> body) {
  final String s;
  try {
    s = utf8.decode(body, allowMalformed: false);
  } catch (_) {
    return null;
  }
  final semi = s.indexOf(';');
  if (semi < 0) {
    return switch (s) {
      '133;A' => const _Osc133PromptStart(),
      '133;B' => const _Osc133PromptEnd(),
      '133;C' => const _Osc133CmdStart(null),
      '133;D' => const _Osc133CmdEnd(null),
      _ => null,
    };
  }
  final kind = s.substring(0, semi);
  final rest = s.substring(semi + 1);
  switch (kind) {
    case '7':
      final uri = Uri.tryParse(rest);
      if (uri != null && uri.path.isNotEmpty) {
        return _Osc7Cwd(Uri.decodeComponent(uri.path));
      }
      return _Osc7Cwd(rest);
    case '133':
      return _parse133(rest);
    case '777':
      return _parse777(rest);
    case '7770':
      final text = _decodeHex(rest);
      return text == null ? null : _Osc7770Cmd(text);
    case '7771':
      final ctx = _parseContextHex(rest);
      return ctx == null ? null : _Osc7771Context(ctx);
    default:
      return null;
  }
}

_OscMarker? _parse133(String rest) {
  final parts = rest.split(';');
  final first = parts.isEmpty ? '' : parts.first;
  switch (first) {
    case 'A':
      return const _Osc133PromptStart();
    case 'B':
      return const _Osc133PromptEnd();
    case 'C':
      final cmdlineUrl =
          parts.length >= 2 ? _parse133CmdlineUrl(parts.sublist(1).join(';')) : null;
      return _Osc133CmdStart(cmdlineUrl);
    case 'D':
      final firstField = parts.length >= 2 ? parts[1].trim() : '';
      return _Osc133CmdEnd(int.tryParse(firstField));
    default:
      return null;
  }
}

_OscMarker? _parse777(String rest) {
  final idx = rest.indexOf(';');
  final first = idx < 0 ? rest : rest.substring(0, idx);
  final tail = idx < 0 ? null : rest.substring(idx + 1);
  switch (first) {
    case 'A':
      return const _Osc133PromptStart();
    case 'B':
      return const _Osc133PromptEnd();
    case 'C':
      return const _Osc133CmdStart(null);
    case 'D':
      final firstField = (tail ?? '').split(';').first.trim();
      return _Osc133CmdEnd(int.tryParse(firstField));
    case 'E':
      if (tail == null) return null;
      final text = _decodeHex(tail);
      return text == null ? null : _Osc7770Cmd(text);
    case 'P':
      if (tail == null) return null;
      if (tail.startsWith('Cwd=')) {
        return _Osc7Cwd(_parseCwd(tail.substring(4)));
      }
      if (tail.startsWith('Context=')) {
        final ctx = _parseContextHex(tail.substring(8));
        return ctx == null ? null : _Osc7771Context(ctx);
      }
      return null;
    default:
      return null;
  }
}

String? _parse133CmdlineUrl(String tail) {
  for (final piece in tail.split(';')) {
    if (piece.startsWith('cmdline_url=')) {
      final raw = piece.substring('cmdline_url='.length);
      try {
        return Uri.decodeComponent(raw);
      } catch (_) {
        return raw;
      }
    }
  }
  return null;
}

String _parseCwd(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri != null && uri.path.isNotEmpty) {
    return Uri.decodeComponent(uri.path);
  }
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

String? _decodeHex(String hex) {
  if (hex.length.isOdd) return null;
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    bytes[i] = byte;
  }
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

Map<String, String>? _parseContextHex(String hex) {
  final json = _decodeHex(hex);
  if (json == null) return null;
  try {
    final obj = jsonDecode(json);
    if (obj is! Map) return null;
    final out = <String, String>{};
    obj.forEach((k, v) {
      if (v is String) out['$k'] = v;
    });
    return out;
  } catch (_) {
    return null;
  }
}
