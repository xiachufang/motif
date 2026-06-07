# Flutter Ghostty — Implementation Plan

A Flutter terminal emulator powered by **libghostty-vt** via `dart:ffi`.

Reference implementation: [ghostling](https://github.com/ghostty-org/ghostling) (Raylib + libghostty-vt in C).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  Flutter App                                        │
│                                                     │
│  ┌──────────────┐   ┌────────────────────────────┐  │
│  │ TerminalView │──▶│ TerminalPainter            │  │
│  │ (StatefulW.) │   │ (CustomPainter)            │  │
│  │              │   │ - draws cells, cursor,     │  │
│  │ - keyboard   │   │   scrollbar via Canvas     │  │
│  │ - mouse      │   └────────────────────────────┘  │
│  │ - focus      │                                   │
│  │ - resize     │   ┌────────────────────────────┐  │
│  └──────┬───────┘   │ GhosttyBindings            │  │
│         │           │ (dart:ffi)                  │  │
│         │           │ - FFI function lookups      │  │
│         ▼           │ - Dart wrappers for C API   │  │
│  ┌──────────────┐   └────────────┬───────────────┘  │
│  │ PtyService   │                │                  │
│  │ (native C)   │◀───────────────┘                  │
│  │ - forkpty    │                                   │
│  │ - read/write │   ┌────────────────────────────┐  │
│  │ - resize     │   │ libghostty-vt.dylib        │  │
│  └──────────────┘   │ (built from ghostty submod)│  │
│                     └────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

---

## Phase 0: Build System — Build libghostty-vt

**Goal:** Produce `libghostty-vt.dylib` from the `ghostty/` submodule and make it loadable by the Flutter macOS app.

### Steps

1. **Build script** (`scripts/build_libghostty.sh`):
   ```bash
   cd ghostty
   zig build lib-vt
   # Output: ghostty/zig-out/lib/libghostty-vt.0.1.0.dylib
   #         ghostty/zig-out/include/ghostty/
   ```

2. **Link into macOS runner:**
   - Copy the built `.dylib` into `macos/Libs/` (or reference from `zig-out/`).
   - Update `macos/Runner/Configs/Debug.xcconfig` and `Release.xcconfig`:
     ```
     OTHER_LDFLAGS=$(inherited) -L$(PROJECT_DIR)/../ghostty/zig-out/lib -lghostty-vt
     LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks $(PROJECT_DIR)/../ghostty/zig-out/lib
     ```
   - Or: embed the dylib into the app bundle's `Frameworks/` via Xcode build phase.

3. **Verify:** `flutter run -d macos` should launch without dylib loading errors.

### Prerequisites

- **Zig 0.15.2** (required by ghostty's build system)
- **cmake** (for building the PTY helper)

---

## Phase 1: FFI Bindings via `ffigen`

**Goal:** Auto-generate Dart FFI bindings from the libghostty-vt C headers using [`package:ffigen`](https://pub.dev/packages/ffigen).

### Setup

1. **Add dev dependency:**
   ```yaml
   # pubspec.yaml
   dev_dependencies:
     ffigen: ^16.0.0
   ```

2. **Create `ffigen.yaml`:**
   ```yaml
   name: GhosttyBindings
   description: Auto-generated bindings for libghostty-vt
   output: 'lib/src/ghostty_bindings.g.dart'
   headers:
     entry-points:
       - 'ghostty/zig-out/include/ghostty/vt.h'
     include-directives:
       - '**ghostty/vt.h'
       - '**ghostty/vt/**'
   compiler-opts:
     - '-Ighostty/zig-out/include'
   comments:
     style: any
     length: full
   ```

3. **Generate bindings:**
   ```bash
   # Must build libghostty-vt first so zig-out/include/ exists
   cd ghostty && zig build lib-vt && cd ..
   dart run ffigen
   # Produces: lib/src/ghostty_bindings.g.dart
   ```

### What ffigen generates

ffigen will auto-generate all of the following from the C headers:

- **Opaque handle types** — `GhosttyTerminal`, `GhosttyRenderState`, `GhosttyKeyEncoder`, etc. as typed `Pointer<>` wrappers
- **Structs** — `GhosttyTerminalOptions`, `GhosttyColorRgb`, `GhosttyStyle`, `GhosttyRenderStateColors`, `GhosttyMouseEncoderSize`, `GhosttyMousePosition`, `GhosttyTerminalScrollbar`, `GhosttyTerminalScrollViewport`, `GhosttyStyleColor`, etc.
- **Enums** — `GhosttyResult`, `GhosttyKey` (~140 values), `GhosttyKeyAction`, `GhosttyRenderStateData`, `GhosttyRenderStateDirty`, `GhosttyCellContentTag`, `GhosttyCellData`, `GhosttyMouseAction`, `GhosttyMouseButton`, `GhosttyFocusEvent`, and all others
- **Constants** — `GHOSTTY_MODS_SHIFT`, `GHOSTTY_MODS_CTRL`, `GHOSTTY_MODS_ALT`, `GHOSTTY_KITTY_KEY_*`, etc.
- **All ~40 C functions** — terminal lifecycle, render state, row/cell iteration, key/mouse encoding, focus encoding, cell/row queries

### Ergonomic Dart wrapper (`lib/src/ghostty.dart`)

A thin hand-written wrapper on top of the generated bindings for Dart-friendly usage:

```dart
class Ghostty {
  final GhosttyBindings _bindings;
  
  Ghostty(DynamicLibrary dylib) : _bindings = GhosttyBindings(dylib);
  
  // Convenience methods that handle pointer allocation/deallocation,
  // sized-struct initialization (setting .size field), and error checking.
}
```

This keeps the generated file untouched (re-runnable) while providing a clean API.

---

## Phase 2: Native PTY Helper (`macos/Runner/Pty.swift` or C via FFI)

**Goal:** Spawn a shell process with a PTY and provide read/write access from Dart.

### Option A: Pure native C via dart:ffi (preferred — no platform channels)

Create a small C file (`native/pty.c`) that exposes:

```c
int pty_spawn(int* master_fd, uint16_t cols, uint16_t rows);
// Returns master_fd. Child runs $SHELL with TERM=xterm-256color.
// Master fd is set to O_NONBLOCK.

ssize_t pty_read(int fd, uint8_t* buf, size_t len);
// Non-blocking read. Returns bytes read or -1 (EAGAIN).

ssize_t pty_write(int fd, const uint8_t* buf, size_t len);
// Write to PTY master.

int pty_resize(int fd, uint16_t cols, uint16_t rows);
// ioctl(TIOCSWINSZ).

void pty_close(int fd, pid_t child);
// close(fd), kill(child, SIGHUP), waitpid.
```

Compile this as a shared library or statically link into the macOS runner.

### Option B: Use `dart:io` `Process` (simpler but less control)

Not recommended — no raw PTY access, no `TIOCSWINSZ`, no `TERM` env.

---

## Phase 3: Terminal State Manager (`lib/src/terminal_state.dart`)

**Goal:** Dart class that owns all ghostty handles and orchestrates the per-frame update loop.

```dart
class TerminalState {
  final GhosttyBindings _b;  // auto-generated by ffigen

  // Opaque handles (typed pointers from ffigen)
  late final GhosttyTerminal _terminal;
  late final GhosttyRenderState _renderState;
  late final GhosttyRenderStateRowIterator _rowIterator;
  late final GhosttyRenderStateRowCells _rowCells;
  late final GhosttyKeyEncoder _keyEncoder;
  late final GhosttyKeyEvent _keyEvent;
  late final GhosttyMouseEncoder _mouseEncoder;
  late final GhosttyMouseEvent _mouseEvent;

  // PTY
  late final int _ptyFd;
  late final int _childPid;

  // Grid dimensions
  int cols, rows;
  double cellWidth, cellHeight;

  void init(int cols, int rows) { /* create all handles, spawn PTY */ }
  void dispose() { /* free all handles, close PTY */ }

  /// Called each frame:
  void readPty() { /* non-blocking read → ghostty_terminal_vt_write */ }
  void updateRenderState() { /* ghostty_render_state_update */ }
  void resize(int newCols, int newRows) { /* terminal_resize + pty_resize */ }

  /// Input encoding:
  Uint8List encodeKey(...) { /* build key event → encode → return bytes */ }
  Uint8List encodeMouse(...) { /* build mouse event → encode → return bytes */ }
  Uint8List encodeFocus(bool gained) { /* ghostty_focus_encode */ }

  /// Render data access:
  RenderStateColors getColors() { ... }
  bool isDirty() { ... }
  void iterateRows(void Function(RowData) callback) { ... }
  CursorInfo? getCursor() { ... }
  ScrollbarInfo getScrollbar() { ... }
}
```

---

## Phase 4: Terminal Renderer (`lib/src/terminal_painter.dart`)

**Goal:** `CustomPainter` that draws the terminal grid cell-by-cell on a Canvas.

### Per-frame render loop (mirrors ghostling's `render_terminal()`)

```
1. Get colors (bg/fg/palette) from render state
2. Fill canvas with background color
3. Iterate rows:
   a. For each row, iterate cells:
      - grapheme_len == 0 → check raw cell for bg-only content → drawRect
      - grapheme_len > 0 →
        • Read codepoints → convert to String
        • Read style (fg/bg colors, bold, italic, inverse, etc.)
        • Resolve colors through palette
        • Handle inverse (swap fg/bg)
        • drawRect for background if non-default
        • drawParagraph/drawText for the glyph
        • Fake bold: draw again offset 1px right
        • Fake italic: apply shear transform
      - Advance x by cellWidth
   b. Clear row dirty flag
   c. Advance y by cellHeight
4. Draw cursor (block/bar/underline based on cursor style)
5. Draw scrollbar thumb
6. Reset global dirty flag
```

### Font handling

- Use a monospace font (e.g., JetBrains Mono bundled as an asset, or system monospace).
- Measure `"M"` glyph to determine `cellWidth` and `cellHeight`.
- Use `TextPainter` or `ParagraphBuilder` for per-cell text rendering.

---

## Phase 5: Terminal Widget (`lib/src/terminal_view.dart`)

**Goal:** Stateful widget that wires input events, layout, and painting together.

```dart
class TerminalView extends StatefulWidget { ... }

class _TerminalViewState extends State<TerminalView> {
  late TerminalState _state;
  late Timer _frameTimer;   // or use Ticker for vsync-aligned frames

  @override
  void initState() {
    _state = TerminalState();
    _state.init(80, 24);
    _startFrameLoop();
  }

  void _startFrameLoop() {
    // ~60fps timer or Ticker
    _frameTimer = Timer.periodic(Duration(milliseconds: 16), (_) {
      _state.readPty();
      _state.updateRenderState();
      if (_state.isDirty()) {
        setState(() {});  // trigger repaint
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onFocusChange: (focused) { /* send focus event to PTY */ },
      onKeyEvent: (node, event) { /* encode key → write to PTY */ },
      child: Listener(
        onPointerDown/Up/Move/Signal: (event) { /* encode mouse → PTY */ },
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Recalculate cols/rows from constraints + cellWidth/cellHeight
            // Call _state.resize() if changed
            return CustomPaint(
              painter: TerminalPainter(_state),
              size: Size(constraints.maxWidth, constraints.maxHeight),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _frameTimer.cancel();
    _state.dispose();
    super.dispose();
  }
}
```

---

## Phase 6: Wire Up `main.dart`

```dart
void main() {
  runApp(MaterialApp(
    home: Scaffold(
      body: TerminalView(),
    ),
  ));
}
```

---

## File Structure

```
flutter_ghostty/
├── ghostty/                          # submodule (ghostty-org/ghostty)
├── native/
│   └── pty.c                         # PTY helper (forkpty, read, write, resize)
├── scripts/
│   └── build_libghostty.sh           # builds libghostty-vt.dylib from submodule
├── ffigen.yaml                       # ffigen configuration
├── lib/
│   ├── main.dart                     # app entry point
│   └── src/
│       ├── ghostty_bindings.g.dart   # AUTO-GENERATED by ffigen (do not edit)
│       ├── ghostty.dart              # thin ergonomic wrapper over generated bindings
│       ├── pty_ffi.dart              # PTY FFI bindings (Phase 2)
│       ├── terminal_state.dart       # state manager (Phase 3)
│       ├── terminal_painter.dart     # CustomPainter renderer (Phase 4)
│       └── terminal_view.dart        # widget (Phase 5)
├── macos/
│   └── Runner/Configs/
│       ├── Debug.xcconfig            # add linker flags for libghostty-vt
│       └── Release.xcconfig          # add linker flags for libghostty-vt
└── pubspec.yaml
```

---

## Key Implementation Details

### Loading the dylib in Dart

```dart
final dylib = DynamicLibrary.open('libghostty-vt.dylib');
final bindings = GhosttyBindings(dylib);  // ffigen-generated class
```

### Sized struct initialization (GHOSTTY_INIT_SIZED equivalent)

In C: `GhosttyStyle s = GHOSTTY_INIT_SIZED(GhosttyStyle);` sets `s.size = sizeof(GhosttyStyle)`.

In Dart FFI: manually set the `size` field before passing to C:
```dart
final colors = calloc<GhosttyRenderStateColors>();
colors.ref.size = sizeOf<GhosttyRenderStateColors>();
ghostty.renderStateColorsGet(renderState, colors);
```

### Flutter key → GhosttyKey mapping

Map `LogicalKeyboardKey` / `PhysicalKeyboardKey` values to `GhosttyKey` constants.
The contiguous ranges (A-Z, 0-9, F1-F12) allow arithmetic mapping like ghostling does with Raylib keys.

### Non-blocking PTY reads

The PTY master fd is set `O_NONBLOCK`. Each frame timer tick calls `read()` in a loop
until `EAGAIN`, feeding all bytes into `ghostty_terminal_vt_write()`.

Since `dart:ffi` calls are synchronous and we're on the main isolate, this is fine
for a 60fps timer — each read drains the kernel buffer (typically <4KB) in microseconds.

### Coordinate system

- `cellWidth` = measured width of monospace glyph "M"
- `cellHeight` = measured height (font ascent + descent)
- `cols` = `(widgetWidth - 2*padding) / cellWidth`
- `rows` = `(widgetHeight - 2*padding) / cellHeight`
- Cell at (col, row) is drawn at pixel `(padding + col*cellWidth, padding + row*cellHeight)`

---

## Build & Run

```bash
# 1. Build libghostty-vt (requires zig 0.15.2)
cd ghostty && zig build lib-vt && cd ..

# 2. Generate FFI bindings (only needed when C headers change)
dart run ffigen

# 3. Run Flutter app
flutter run -d macos
```

---

## Future / Nice-to-Have

- **Selection** (text selection with mouse drag)
- **Copy/paste** integration
- **URL detection** (hyperlink cells)
- **Sixel / Kitty image protocol** support
- **Multi-tab** terminal sessions
- **Theme customization** (pass custom palette to terminal)
- **Linux / Windows** platform support (PTY abstraction per platform)
