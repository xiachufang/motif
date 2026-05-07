//! Embedded Tailscale support for motif clients.
//!
//! This crate is the Rust safe wrapper around `libtailscale` (Tailscale's
//! C-ABI exposure of `tsnet`). See `docs/tailscale.md` for design.
//!
//! ## Build modes
//!
//! - **`stub`** (default): no `libtailscale` is linked. All API calls return
//!   `TsError::Unimplemented` at runtime. This lets downstream crates depend
//!   on the API surface without requiring a Go toolchain. v1.5 skeleton ships
//!   in this mode — implementing the actual FFI is a follow-up task tracked
//!   in `docs/tailscale.md` §12.
//!
//! - **`bundled`**: invoke `go build -buildmode=c-archive` against the
//!   vendored `libtailscale` submodule, generate FFI bindings via `bindgen`,
//!   and link statically. **Not yet implemented**; planned next iteration.
//!
//! - **`prebuilt`**: pull a precompiled `libtailscale-<target>.tar.gz` from
//!   the upstream GitHub release matching `vendor/libtailscale/VERSION`,
//!   verify checksum, and link statically. **Not yet implemented**.

use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum TsError {
    #[error("Tailscale support is not implemented in this build (enable feature `bundled` or `prebuilt`)")]
    Unimplemented,
    #[error("libtailscale call failed: {0}")]
    Native(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone)]
pub struct TsOptions {
    pub hostname:    String,
    pub state_dir:   PathBuf,
    pub authkey:     Option<String>,
    pub control_url: Option<String>,
    pub ephemeral:   bool,
}

#[derive(Debug, Clone)]
pub struct TsPeer {
    pub hostname: String,
    pub ip:       String,
    pub os:       String,
    pub online:   bool,
}

/// A logical Tailscale node embedded in the current process.
pub struct TsServer {
    _opts: TsOptions,
    #[cfg(feature = "stub")]
    _marker: std::marker::PhantomData<()>,
}

impl TsServer {
    pub fn new(opts: TsOptions) -> Result<Self, TsError> {
        tracing::debug!(hostname = %opts.hostname, "TsServer::new (stub)");
        Ok(Self { _opts: opts, #[cfg(feature = "stub")] _marker: std::marker::PhantomData })
    }

    /// Bring the node up — block until joined to the tailnet.
    pub async fn up(&self) -> Result<(), TsError> {
        Err(TsError::Unimplemented)
    }

    pub async fn dial_tcp(&self, _addr: &str) -> Result<TsStream, TsError> {
        Err(TsError::Unimplemented)
    }

    pub async fn list_peers(&self) -> Result<Vec<TsPeer>, TsError> {
        Err(TsError::Unimplemented)
    }
}

/// An async TCP stream over the tailnet.
///
/// Real implementation will own a tokio::io::DuplexStream wired to an
/// libtailscale-backed file descriptor. The stub never constructs an instance.
pub struct TsStream { _private: () }

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn options_construct() {
        let o = TsOptions {
            hostname: "test".into(),
            state_dir: PathBuf::from("/tmp/motif-tailscale-test"),
            authkey: None,
            control_url: None,
            ephemeral: true,
        };
        let _s = TsServer::new(o).unwrap();
    }
}
