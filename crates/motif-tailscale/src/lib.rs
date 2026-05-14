//! Embedded Tailscale support for motif.
//!
//! With `--features bundled` this crate wraps the
//! [`libtailscale`](https://crates.io/crates/libtailscale) Rust binding,
//! which itself shells out to a vendored Go-built `libtailscale.a` (via
//! `libtailscale-sys`'s build.rs). Without the feature, every runtime call
//! returns `TsError::Unimplemented` so downstream crates compile without a
//! Go toolchain.
//!
//! The public surface (`TsServer`, `TsStream`, `TsListener`,
//! `TsOptions`, `TsError`) is identical between the two modes — only the
//! bodies change. That's what lets `motif-net` consume this crate without
//! conditional compilation past the feature gate it already has on the
//! tailscale path.

use std::path::PathBuf;

#[cfg(feature = "bundled")]
mod bundled;
#[cfg(not(feature = "bundled"))]
mod stub;

#[cfg(feature = "bundled")]
pub use bundled::{TsBackendStatus, TsListener, TsServer, TsStream};
#[cfg(not(feature = "bundled"))]
pub use stub::{TsBackendStatus, TsListener, TsServer, TsStream};

#[derive(Debug, thiserror::Error)]
pub enum TsError {
    #[error("Tailscale support is not implemented in this build (enable feature `bundled`)")]
    Unimplemented,
    #[error("libtailscale call failed: {0}")]
    Native(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone)]
pub struct TsOptions {
    pub hostname: String,
    pub state_dir: PathBuf,
    pub authkey: Option<String>,
    pub control_url: Option<String>,
    pub ephemeral: bool,
}

#[derive(Debug, Clone)]
pub struct TsPeer {
    pub hostname: String,
    pub ip: String,
    pub os: String,
    pub online: bool,
}
