//! Motif protocol types — shared by server and clients.
//!
//! Wire format: JSON-RPC 2.0 over WebSocket. See `docs/prd.md` §5.

pub mod common;
pub mod envelope;
pub mod error;
pub mod event;
pub mod fs;
pub mod git;
pub mod pty;
pub mod session;
pub mod terminal_query;
pub mod view;
pub mod wire;

pub use common::*;
pub use envelope::*;
pub use error::*;
pub use event::Event;
