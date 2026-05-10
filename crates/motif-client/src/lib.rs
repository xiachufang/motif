//! Motif RPC client shared between `motif-tui` (rich UI) and `motif-cast`
//! (raw passthrough). Pure JSON-RPC + WebSocket transport — no TUI deps.

pub mod client;
pub mod palette;
pub mod raw_pty;
pub mod transport;
