import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../theme/motif_theme.dart';

/// Font size + theme controls (mirrors TerminalSettingsSheet).
class TerminalSettingsSheet extends StatelessWidget {
  const TerminalSettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final store = app.terminalSettings;
    final s = store.settings;
    final c = context.motif;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(MotifSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Terminal',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: MotifSpacing.lg),
            Row(
              children: [
                Text(
                  'Font size',
                  style: TextStyle(color: c.textPrimary, fontSize: 15),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: s.fontSize > TerminalSettings.minFontSize
                      ? () => store.setFontSize(s.fontSize - 1)
                      : null,
                ),
                Text(
                  '${s.fontSize.toStringAsFixed(0)} pt',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontFeatures: const [],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: s.fontSize < TerminalSettings.maxFontSize
                      ? () => store.setFontSize(s.fontSize + 1)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: MotifSpacing.md),
            Text('Theme', style: TextStyle(color: c.textPrimary, fontSize: 15)),
            const SizedBox(height: MotifSpacing.sm),
            SegmentedButton<TerminalThemeSetting>(
              segments: const [
                ButtonSegment(
                  value: TerminalThemeSetting.light,
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: TerminalThemeSetting.dark,
                  label: Text('Dark'),
                ),
                ButtonSegment(
                  value: TerminalThemeSetting.system,
                  label: Text('System'),
                ),
              ],
              selected: {s.theme},
              onSelectionChanged: (sel) => store.setTheme(sel.first),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showTerminalSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const TerminalSettingsSheet(),
  );
}
