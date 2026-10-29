# Ghostty integration

Motif pins `apps/flutter/ghostty` to upstream commit
`b2c78c9bd9bc88a16d9c3769b0fb17ddde1b78b1` (1.4.1-dev).
Native, Rust and WebAssembly builds use this same checkout and Zig 0.17.0.

No local patches are currently needed. The previous vertical overscan patch
is replaced by upstream `GHOSTTY_RENDER_STATE_OPTION_OVERSCAN`, with one row
requested above and below the viewport.

When upgrading the submodule, regenerate both the Rust and Dart bindings
from its headers and rebuild the ignored WebAssembly artifact.

Regenerate the checked-in bindings from the pinned headers:

```sh
GHOSTTY_INCLUDE_DIR="$PWD/apps/flutter/ghostty/include" \
  cargo run -p libghostty-vt-sys --features bindgen-tool --bin gen-bindings
(cd apps/flutter && dart run ffigen --config ffigen.yaml)
```

Build and smoke-test the WebAssembly bridge (text, colors, cursor, scrollback,
overscan, keys and paste):

```sh
apps/flutter/scripts/build_ghostty_wasm.sh
node scripts/test_ghostty_wasm.cjs
```
