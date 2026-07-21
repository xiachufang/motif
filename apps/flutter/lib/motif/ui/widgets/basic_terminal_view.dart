import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../terminal/terminal_fonts.dart';
import '../../terminal/terminal_session.dart';
import '../theme/motif_theme.dart';

/// A minimal, cross-platform remote-output view used until the full libghostty
/// renderer is wired (see task #8 / `MOTIF_FLUTTER_PLAN.md` P2). It subscribes
/// to a PTY's decoded byte stream, applies a *very* small subset of terminal
/// handling (CR/LF, backspace, naive CSI/ OSC stripping) and shows the result
/// as monospace scrollback. Good enough to prove the end-to-end pipe and run
/// line-oriented commands; not a substitute for real VT emulation.
class BasicTerminalView extends StatefulWidget {
  final TerminalSession terminal;
  final String ptyId;
  final double fontSize;

  const BasicTerminalView({
    super.key,
    required this.terminal,
    required this.ptyId,
    this.fontSize = 13,
  });

  @override
  State<BasicTerminalView> createState() => _BasicTerminalViewState();
}

class _BasicTerminalViewState extends State<BasicTerminalView> {
  final List<String> _lines = [''];
  final ScrollController _scroll = ScrollController();
  final StringBuffer _decodeCarry = StringBuffer();

  static const int _maxLines = 5000;

  @override
  void initState() {
    super.initState();
    widget.terminal.registerPtySink(widget.ptyId, _onBytes);
  }

  @override
  void didUpdateWidget(covariant BasicTerminalView old) {
    super.didUpdateWidget(old);
    if (old.ptyId != widget.ptyId) {
      widget.terminal.unregisterPtySink(old.ptyId);
      widget.terminal.registerPtySink(widget.ptyId, _onBytes);
    }
  }

  @override
  void dispose() {
    widget.terminal.unregisterPtySink(widget.ptyId);
    _scroll.dispose();
    super.dispose();
  }

  void _onBytes(Uint8List bytes) {
    final text = _stripEscapes(utf8.decode(bytes, allowMalformed: true));
    _appendText(text);
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _appendText(String text) {
    for (final rune in text.runes) {
      switch (rune) {
        case 0x0a: // \n
          _lines.add('');
        case 0x0d: // \r — return to line start (approx: clear current line)
          _lines[_lines.length - 1] = '';
        case 0x08: // backspace
          final last = _lines.last;
          if (last.isNotEmpty) {
            _lines[_lines.length - 1] = last.substring(0, last.length - 1);
          }
        default:
          if (rune >= 0x20) {
            _lines[_lines.length - 1] += String.fromCharCode(rune);
          }
      }
    }
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
  }

  /// Strip CSI (`ESC [ … final`) and OSC (`ESC ] … BEL/ST`) sequences. Anything
  /// the parser doesn't recognize is dropped to keep the text readable.
  String _stripEscapes(String input) {
    final out = StringBuffer(_decodeCarry.toString());
    _decodeCarry.clear();
    final s = input;
    var i = 0;
    while (i < s.length) {
      final ch = s.codeUnitAt(i);
      if (ch == 0x1b) {
        // ESC — try to consume a CSI/OSC.
        if (i + 1 >= s.length) {
          _decodeCarry.write('\x1b');
          break;
        }
        final next = s.codeUnitAt(i + 1);
        if (next == 0x5b) {
          // CSI: ESC [ params final(0x40–0x7e)
          var j = i + 2;
          while (j < s.length &&
              !(s.codeUnitAt(j) >= 0x40 && s.codeUnitAt(j) <= 0x7e)) {
            j++;
          }
          if (j >= s.length) {
            _decodeCarry.write(s.substring(i));
            break;
          }
          i = j + 1;
          continue;
        } else if (next == 0x5d) {
          // OSC: ESC ] … (BEL | ESC \)
          var j = i + 2;
          while (j < s.length && s.codeUnitAt(j) != 0x07) {
            if (s.codeUnitAt(j) == 0x1b &&
                j + 1 < s.length &&
                s.codeUnitAt(j + 1) == 0x5c) {
              j++;
              break;
            }
            j++;
          }
          if (j >= s.length) {
            _decodeCarry.write(s.substring(i));
            break;
          }
          i = j + 1;
          continue;
        } else {
          i += 2; // skip ESC + one byte
          continue;
        }
      }
      out.writeCharCode(ch);
      i++;
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final font = platformTerminalFont();
    return Container(
      color: c.background,
      padding: const EdgeInsets.all(MotifSpacing.sm),
      child: SelectionArea(
        child: ListView.builder(
          controller: _scroll,
          itemCount: _lines.length,
          itemBuilder: (context, i) => Text(
            _lines[i],
            style: TextStyle(
              fontFamily: font.family,
              fontFamilyFallback: font.fallback,
              fontSize: widget.fontSize,
              color: c.textPrimary,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}
