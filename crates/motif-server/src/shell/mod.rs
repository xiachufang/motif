//! v2 shell integration. Detects shell kind, materializes bootstrap
//! scripts to a per-PTY tmpdir, and injects them into PTY spawn so the
//! shell emits OSC markers (133 / 7 / 7770 / 7771). The reader loop in
//! `pty.rs` feeds those markers through [`state::ShellState`] which
//! turns them into [`state::ShellEvent`]s, and finished blocks are
//! pushed into a per-PTY [`block_store::BlockStore`] for backfill.

pub mod block_store;
pub mod bootstrap;
pub mod state;

pub use block_store::{Block, BlockStore, DEFAULT_CAP_COUNT, DEFAULT_CAP_TOTAL_BYTES};
pub use bootstrap::{detect, Bootstrap};
pub use state::{BlockState, ShellEvent, ShellState};
