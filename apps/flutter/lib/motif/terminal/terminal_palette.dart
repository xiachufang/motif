import 'dart:ui' as ui;

class TerminalPalette {
  final String theme;
  final String foregroundWire;
  final String backgroundWire;
  final ui.Color foreground;
  final ui.Color background;

  const TerminalPalette({
    required this.theme,
    required this.foregroundWire,
    required this.backgroundWire,
    required this.foreground,
    required this.background,
  });
}

TerminalPalette terminalPaletteForBrightness(ui.Brightness brightness) {
  return switch (brightness) {
    ui.Brightness.dark => const TerminalPalette(
      theme: 'dark',
      foregroundWire: 'd0d0/d0d0/d0d0',
      backgroundWire: '2121/2121/2121',
      foreground: ui.Color(0xFFD0D0D0),
      background: ui.Color(0xFF212121),
    ),
    ui.Brightness.light => const TerminalPalette(
      theme: 'light',
      foregroundWire: '0000/0000/0000',
      backgroundWire: 'f7f7/f7f7/f7f7',
      foreground: ui.Color(0xFF000000),
      background: ui.Color(0xFFF7F7F7),
    ),
  };
}
