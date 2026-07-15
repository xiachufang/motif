//! Transport abstraction for motif binaries.
//!
//! The available backends are plain TCP, WSS rendezvous, and embedded
//! Tailscale via `motif-tailscale` (gated behind the `tailscale` feature).
//! Both server-side accept and client-side dial flow through this crate, so
//! `motifd`, `motif-tui`, and `motif-cast` don't each have to branch on
//! `TcpStream` vs `TsStream`.
//!
//! Server side: build a [`Listener`] from a [`ListenConfig`] and hand it to
//! `axum::serve` — [`Listener`] implements `axum::serve::Listener`. With
//! multiple listener backends set in the config, accepts are fanned in
//! concurrently.
//!
//! Client side: call [`dial`] with a [`DialTarget`] to get back a
//! [`Stream`], then feed it to `tokio_tungstenite::client_async`.

pub mod config;
pub mod dialer;
pub mod listener;
pub mod stream;

pub use config::{DialTarget, ListenConfig, RzvListenConfig, TailscaleListenConfig};
pub use dialer::{dial, NetError};
pub use listener::{Listener, PeerAddr};
pub use stream::Stream;

#[cfg(feature = "tailscale")]
pub use motif_tailscale;
