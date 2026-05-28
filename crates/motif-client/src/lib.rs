//! Motif RPC client shared between `motif-tui` (rich UI) and `motif-cast`
//! (raw passthrough). New-protocol transport: HTTP for RPC, separate
//! WebSockets for the structured event stream and each PTY's raw byte
//! channel.

pub mod coordinator;
pub mod events;
pub mod focus;
pub mod http;
pub mod palette;
pub mod pty_ws;
pub mod raw_pty;
/// Phase-5b: client-side shell-integration OSC parser. Drives a per-
/// PTY block state machine off shell-integration markers that the server
/// now passes through unchanged. Lifted from the (now-deleted)
/// server-side `shell/state.rs`.
pub mod shell_integration;
pub mod transport;

/// Re-exported so callers (motif-tui, motif-cast) can reach
/// `motif_net::motif_tailscale::*` for tsnet-aware commands without
/// adding a separate Cargo dependency.
pub use motif_net;
