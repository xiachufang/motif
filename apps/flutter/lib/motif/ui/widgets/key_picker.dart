import 'package:flutter/material.dart';

import '../../terminal/terminal_key.dart';
import '../theme/motif_theme.dart';
import 'adaptive_modal.dart';

/// A named semantic terminal key.
class TerminalKeyDef {
  /// Full name shown in the picker (e.g. 'Page Up').
  final String name;

  /// Short label used on quick-command chips (e.g. 'PgUp', '↑').
  final String label;

  /// Optional symbol name rendered as an icon by QuickCommandRow.
  final String? symbol;

  final String keyId;

  const TerminalKeyDef(this.name, this.label, this.keyId, {this.symbol});
}

class TerminalKeyCategory {
  final String name;
  final List<TerminalKeyDef> keys;
  const TerminalKeyCategory(this.name, this.keys);
}

/// A printable character key: the byte is just its ASCII code.
TerminalKeyDef _charKey(String ch) =>
    TerminalKeyDef(ch, ch, TerminalKeyIds.character(ch));

/// Keyboard keys selectable as quick-command payloads, grouped for display.
/// Encoding is deferred to Ghostty using the active terminal modes.
final terminalKeyCatalog = [
  const TerminalKeyCategory('Control', [
    TerminalKeyDef('Escape', 'Esc', TerminalKeyIds.escape),
    TerminalKeyDef(
      'Tab',
      'Tab',
      TerminalKeyIds.tab,
      symbol: 'arrow.right.to.line',
    ),
    TerminalKeyDef('Enter', 'Enter', TerminalKeyIds.enter),
    TerminalKeyDef('Space', 'Space', TerminalKeyIds.space),
    TerminalKeyDef(
      'Backspace',
      'Bksp',
      TerminalKeyIds.backspace,
      symbol: 'delete.left',
    ),
    TerminalKeyDef(
      'Delete',
      'Del',
      TerminalKeyIds.delete,
      symbol: 'delete.right',
    ),
    TerminalKeyDef('Insert', 'Ins', TerminalKeyIds.insert),
  ]),
  const TerminalKeyCategory('Arrows', [
    TerminalKeyDef('Up', '↑', TerminalKeyIds.arrowUp, symbol: 'arrow.up'),
    TerminalKeyDef('Down', '↓', TerminalKeyIds.arrowDown, symbol: 'arrow.down'),
    TerminalKeyDef('Left', '←', TerminalKeyIds.arrowLeft, symbol: 'arrow.left'),
    TerminalKeyDef(
      'Right',
      '→',
      TerminalKeyIds.arrowRight,
      symbol: 'arrow.right',
    ),
  ]),
  const TerminalKeyCategory('Navigation', [
    TerminalKeyDef('Home', 'Home', TerminalKeyIds.home),
    TerminalKeyDef('End', 'End', TerminalKeyIds.end),
    TerminalKeyDef('Page Up', 'PgUp', TerminalKeyIds.pageUp),
    TerminalKeyDef('Page Down', 'PgDn', TerminalKeyIds.pageDown),
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
    TerminalKeyDef('F1', 'F1', TerminalKeyIds.f1),
    TerminalKeyDef('F2', 'F2', TerminalKeyIds.f2),
    TerminalKeyDef('F3', 'F3', TerminalKeyIds.f3),
    TerminalKeyDef('F4', 'F4', TerminalKeyIds.f4),
    TerminalKeyDef('F5', 'F5', TerminalKeyIds.f5),
    TerminalKeyDef('F6', 'F6', TerminalKeyIds.f6),
    TerminalKeyDef('F7', 'F7', TerminalKeyIds.f7),
    TerminalKeyDef('F8', 'F8', TerminalKeyIds.f8),
    TerminalKeyDef('F9', 'F9', TerminalKeyIds.f9),
    TerminalKeyDef('F10', 'F10', TerminalKeyIds.f10),
    TerminalKeyDef('F11', 'F11', TerminalKeyIds.f11),
    TerminalKeyDef('F12', 'F12', TerminalKeyIds.f12),
  ]),
];

TerminalKeyDef? terminalKeyForId(String? keyId) {
  if (keyId == null) return null;
  for (final category in terminalKeyCatalog) {
    for (final key in category.keys) {
      if (key.keyId == keyId) return key;
    }
  }
  return null;
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
