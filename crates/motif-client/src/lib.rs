//! Motif RPC client shared between `motif-tui` (rich UI) and `motif-cast`
//! (raw passthrough). Pure JSON-RPC + WebSocket transport — no TUI deps.

pub mod client;
pub mod palette;
pub mod raw_pty;
pub mod transport;

/// Re-exported so callers (motif-tui, motif-cast) can reach
/// `motif_net::motif_tailscale::*` for tsnet-aware commands without
/// adding a separate Cargo dependency.
pub use motif_net;
