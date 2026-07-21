import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../models/settings.dart';
import '../../state/app/app_state.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';

part 'terminal_settings_sheet.g.dart';

/// Font size + theme controls (mirrors TerminalSettingsSheet).
@ObservationWidget()
class TerminalSettingsSheet extends _$TerminalSettingsSheet {
  const TerminalSettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ObservationScope.of<AppState>(context);
    final store = app.terminalSettings;
    final s = store.settings;
    final c = context.motif;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MotifSection(
          title: 'Appearance',
          dividerIndent: MotifSpacing.lg,
          children: [
            MotifSectionRow(
              title: 'Font size',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
            ),
            Padding(
              padding: const EdgeInsets.all(MotifSpacing.sm),
              child: SegmentedButton<TerminalThemeSetting>(
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
            ),
          ],
        ),
      ],
    );
  }
}

Future<void> showTerminalSettingsSheet(BuildContext context) {
  return showAdaptiveModal<void>(
    context,
    builder: (_) => AdaptiveModal(
      title: 'Terminal',
      content: const TerminalSettingsSheet(),
    ),
  );
}
