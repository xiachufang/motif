# libghostty-vt-sys

Raw FFI bindings for libghostty-vt.

- Builds `libghostty-vt.a` from Motif's `apps/flutter/ghostty` checkout via Zig
  by default, so the Rust and Flutter bindings always share one C ABI.
- Exposes checked-in generated bindings in `src/bindings.rs`.
- Static linking is the baseline rather than a Cargo feature. Enable the
  additive `link-dynamic` feature to link the shared library instead.
- Set `GHOSTTY_SOURCE_DIR` to override that checkout explicitly.
- Set `GHOSTTY_ZIG_SYSTEM_DIR` to force Zig package resolution through a
  pre-fetched `zig build --system` directory. This is intended for Nix and other
  sandboxed package managers that cannot fetch during build scripts.
- Set `LIBGHOSTTY_VT_SYS_OPTIMIZE` to `Debug`, `ReleaseSafe`, `ReleaseFast`, or
  `ReleaseSmall` to override the Zig optimize mode used by vendored builds.
- If the `pkg-config` feature is enabled, the build will use an installed
  `libghostty-vt` found through `pkg-config` only when `GHOSTTY_SOURCE_DIR` is
  unset. With the default static link mode, it probes Ghostty's
  `libghostty-vt-static` pkg-config module instead.
- libghostty-vt is pre-1.0, so these bindings do not guarantee compatibility
  with arbitrary installed C API revisions.
