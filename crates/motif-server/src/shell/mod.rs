//! v2 shell-integration bootstrap: detects shell kind, materializes
//! bootstrap scripts to a per-PTY tmpdir, and injects them into PTY
//! spawn so the shell emits Motif private OSC 7777 markers.
//!
//! Shell-integration **parsing** lives client-side now (Phase 5b of
//! the protocol redesign) — the server no longer drives a state
//! machine or stores command blocks. Only bootstrap injection
//! remains here.

pub mod bootstrap;

pub use bootstrap::{detect, Bootstrap};
