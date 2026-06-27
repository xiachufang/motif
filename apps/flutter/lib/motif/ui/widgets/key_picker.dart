import 'package:flutter/material.dart';

import '../theme/motif_theme.dart';
import 'adaptive_modal.dart';

/// A named terminal key with its xterm byte sequence.
class TerminalKeyDef {
  /// Full name shown in the picker (e.g. 'Page Up').
  final String name;

  /// Short label used on quick-command chips (e.g. 'PgUp', '↑').
  final String label;

  /// Optional symbol name rendered as an icon by QuickCommandRow.
  final String? symbol;

  final List<int> bytes;

  const TerminalKeyDef(this.name, this.label, this.bytes, {this.symbol});
}

class TerminalKeyCategory {
  final String name;
  final List<TerminalKeyDef> keys;
  const TerminalKeyCategory(this.name, this.keys);
}

/// A printable character key: the byte is just its ASCII code.
TerminalKeyDef _charKey(String ch) =>
    TerminalKeyDef(ch, ch, [ch.codeUnitAt(0)]);

/// Keyboard keys selectable as quick-command payloads, grouped for display.
/// Byte sequences match xterm defaults (what the ghostty encoder emits).
final terminalKeyCatalog = [
  const TerminalKeyCategory('Control', [
    TerminalKeyDef('Escape', 'Esc', [0x1b]),
    TerminalKeyDef('Tab', 'Tab', [0x09], symbol: 'arrow.right.to.line'),
    TerminalKeyDef('Enter', 'Enter', [0x0d]),
    TerminalKeyDef('Space', 'Space', [0x20]),
    TerminalKeyDef('Backspace', 'Bksp', [0x7f], symbol: 'delete.left'),
    TerminalKeyDef('Delete', 'Del', [
      0x1b,
      0x5b,
      0x33,
      0x7e,
    ], symbol: 'delete.right'),
    TerminalKeyDef('Insert', 'Ins', [0x1b, 0x5b, 0x32, 0x7e]),
  ]),
  const TerminalKeyCategory('Arrows', [
    TerminalKeyDef('Up', '↑', [0x1b, 0x5b, 0x41], symbol: 'arrow.up'),
    TerminalKeyDef('Down', '↓', [0x1b, 0x5b, 0x42], symbol: 'arrow.down'),
    TerminalKeyDef('Left', '←', [0x1b, 0x5b, 0x44], symbol: 'arrow.left'),
    TerminalKeyDef('Right', '→', [0x1b, 0x5b, 0x43], symbol: 'arrow.right'),
  ]),
  const TerminalKeyCategory('Navigation', [
    TerminalKeyDef('Home', 'Home', [0x1b, 0x5b, 0x48]),
    TerminalKeyDef('End', 'End', [0x1b, 0x5b, 0x46]),
    TerminalKeyDef('Page Up', 'PgUp', [0x1b, 0x5b, 0x35, 0x7e]),
    TerminalKeyDef('Page Down', 'PgDn', [0x1b, 0x5b, 0x36, 0x7e]),
  ]),
  TerminalKeyCategory('Letters', [
    for (var c = 0x61; c <= 0x7a; c++) _charKey(String.fromCharCode(c)),
  ]),
  TerminalKeyCategory('Digits', [
    for (var c = 0x30; c <= 0x39; c++) _charKey(String.fromCharCode(c)),
  ]),
  TerminalKeyCategory('Symbols', [
    for (final ch
        in (r"`~!@#$%^&*()-_=+[]{}\|;:'"
                '",.<>/?')
            .split(''))
      _charKey(ch),
  ]),
  const TerminalKeyCategory('Function', [
    TerminalKeyDef('F1', 'F1', [0x1b, 0x4f, 0x50]),
    TerminalKeyDef('F2', 'F2', [0x1b, 0x4f, 0x51]),
    TerminalKeyDef('F3', 'F3', [0x1b, 0x4f, 0x52]),
    TerminalKeyDef('F4', 'F4', [0x1b, 0x4f, 0x53]),
    TerminalKeyDef('F5', 'F5', [0x1b, 0x5b, 0x31, 0x35, 0x7e]),
    TerminalKeyDef('F6', 'F6', [0x1b, 0x5b, 0x31, 0x37, 0x7e]),
    TerminalKeyDef('F7', 'F7', [0x1b, 0x5b, 0x31, 0x38, 0x7e]),
    TerminalKeyDef('F8', 'F8', [0x1b, 0x5b, 0x31, 0x39, 0x7e]),
    TerminalKeyDef('F9', 'F9', [0x1b, 0x5b, 0x32, 0x30, 0x7e]),
    TerminalKeyDef('F10', 'F10', [0x1b, 0x5b, 0x32, 0x31, 0x7e]),
    TerminalKeyDef('F11', 'F11', [0x1b, 0x5b, 0x32, 0x33, 0x7e]),
    TerminalKeyDef('F12', 'F12', [0x1b, 0x5b, 0x32, 0x34, 0x7e]),
  ]),
];

/// Find the catalog key whose byte sequence equals [bytes], if any.
TerminalKeyDef? terminalKeyForBytes(List<int> bytes) {
  for (final category in terminalKeyCatalog) {
    for (final key in category.keys) {
      if (_bytesEqual(key.bytes, bytes)) return key;
    }
  }
  return null;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Categorized keyboard-key picker; resolves to the chosen key or null.
Future<TerminalKeyDef?> showKeyPicker(BuildContext context) {
  return showAdaptivePanel<TerminalKeyDef>(
    context,
    builder: (_) => const _KeyPickerPanel(),
  );
}

class _KeyPickerPanel extends StatelessWidget {
  const _KeyPickerPanel();

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return AdaptivePanel(
      title: 'Select key',
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(
          MotifSpacing.lg,
          MotifSpacing.md,
          MotifSpacing.lg,
          MotifSpacing.xl,
        ),
        children: [
          for (final category in terminalKeyCatalog) ...[
            Padding(
              padding: const EdgeInsets.only(
                top: MotifSpacing.md,
                bottom: MotifSpacing.sm,
              ),
              child: Text(
                category.name.toUpperCase(),
                style: MotifType.caption.copyWith(
                  color: c.textTertiary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Wrap(
              spacing: MotifSpacing.sm,
              runSpacing: MotifSpacing.sm,
              children: [
                for (final key in category.keys)
                  Tooltip(
                    message: key.name,
                    child: ActionChip(
                      label: Text(
                        key.label,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      onPressed: () => Navigator.pop(context, key),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
