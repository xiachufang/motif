//! Push-relay client + per-device end-to-end encryption.
//!
//! motifd never holds the APNs `.p8` signing key — that lives only on the
//! author-operated relay. motifd forwards an opaque, **encrypted** payload to
//! the relay; the relay signs an APNs JWT and delivers it. Because the relay
//! is a third party from a self-hoster's point of view, notification content
//! (which may include code, file paths, Claude's messages) is encrypted with a
//! per-device AES-256-GCM key shared only between motifd and the device (over
//! the already-authenticated RPC channel). The relay sees only ciphertext.
//!
//! TLS uses the `ring` provider via `hyper-rustls`, deliberately not
//! aws-lc-rs — see the dependency note in the workspace `Cargo.toml`.

use std::sync::Arc;

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde::Serialize;

use crate::devices::DeviceStore;

/// Shared push state hung off `ws::AppState` and reused by the hook-ingress
/// task. Cheap to clone (`Arc` + a pooled client).
#[derive(Clone)]
pub struct DeviceState {
    pub store: Arc<DeviceStore>,
    pub relay: Option<RelayClient>,
}

impl DeviceState {
    pub fn instance_id(&self) -> String {
        self.store.instance_id()
    }
}

/// A user-facing notification to deliver. Built by the hook-ingress handler.
#[derive(Debug, Clone)]
pub struct PushNotification {
    pub title: String,
    pub body: String,
    pub session_id: Option<String>,
    /// Coarse kind, e.g. `"needs_input"` / `"finished"`.
    pub kind: String,
}

#[derive(Serialize)]
struct EncMotif<'a> {
    instance_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<&'a str>,
    kind: &'a str,
}

#[derive(Serialize)]
struct Plaintext<'a> {
    title: &'a str,
    body: &'a str,
    motif: EncMotif<'a>,
}

#[derive(Serialize)]
struct RelayBody<'a> {
    device_token: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    environment: Option<&'a str>,
    /// Base64 ciphertext (includes the 16-byte GCM tag appended).
    e: String,
    /// Base64 12-byte nonce.
    n: String,
}

type HttpsClient = Client<
    hyper_rustls::HttpsConnector<hyper_util::client::legacy::connect::HttpConnector>,
    Full<Bytes>,
>;

#[derive(Clone)]
pub struct RelayClient {
    client: HttpsClient,
    relay_url: Arc<String>,
}

impl RelayClient {
    pub fn new(relay_url: String) -> Self {
        let https = hyper_rustls::HttpsConnectorBuilder::new()
            .with_webpki_roots()
            .https_or_http()
            .enable_http1()
            .build();
        let client = Client::builder(TokioExecutor::new()).build(https);
        Self {
            client,
            relay_url: Arc::new(relay_url),
        }
    }

    /// Encrypt `notif` per device and POST each to the relay concurrently.
    /// Best-effort: a failure for one device is logged and skipped; a relay
    /// 404/410 prunes that token from the store.
    pub async fn push_to_all(&self, store: &DeviceStore, notif: &PushNotification) {
        let instance_id = store.instance_id();
        let mut devices = store.all();
        // Per-session mute: when the notification is attributable to a session,
        // drop devices that muted it. An unattributed hook (session_id == None,
        // e.g. fired outside a motif PTY) still goes to everyone.
        if let Some(session) = notif.session_id.as_deref() {
            devices.retain(|d| !d.muted_sessions.contains(session));
        }
        if devices.is_empty() {
            return;
        }
        let plain = match serde_json::to_vec(&Plaintext {
            title: &notif.title,
            body: &notif.body,
            motif: EncMotif {
                instance_id: &instance_id,
                session_id: notif.session_id.as_deref(),
                kind: &notif.kind,
            },
        }) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("push: failed to serialize plaintext: {e}");
                return;
            }
        };

        let futs = devices.into_iter().map(|d| {
            let plain = plain.clone();
            async move {
                match self.push_one(&d.device_token, d.environment.as_deref(), &d.enc_key, &plain).await {
                    Ok(true) => {}
                    Ok(false) => {
                        tracing::info!("push: relay reported token gone; pruning");
                        store.prune(&d.device_token);
                    }
                    Err(e) => tracing::warn!("push: relay POST failed: {e}"),
                }
            }
        });
        futures_util::future::join_all(futs).await;
    }

    /// Returns `Ok(true)` on success, `Ok(false)` if the token should be
    /// pruned (relay said it's invalid), `Err` on transport/encryption error.
    async fn push_one(
        &self,
        device_token: &str,
        environment: Option<&str>,
        enc_key_b64: &str,
        plaintext: &[u8],
    ) -> anyhow::Result<bool> {
        let (e, n) = encrypt(enc_key_b64, plaintext)?;
        let body = serde_json::to_vec(&RelayBody {
            device_token,
            environment,
            e,
            n,
        })?;
        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri(self.relay_url.as_str())
            .header(http::header::CONTENT_TYPE, "application/json")
            .body(Full::new(Bytes::from(body)))?;
        let resp = self.client.request(req).await?;
        let status = resp.status();
        // Drain the body so the connection can be pooled.
        let _ = resp.into_body().collect().await;
        if status.is_success() {
            Ok(true)
        } else if status == http::StatusCode::GONE || status == http::StatusCode::NOT_FOUND {
            Ok(false)
        } else {
            anyhow::bail!("relay returned status {status}");
        }
    }
}

/// AES-256-GCM encrypt with a fresh random 12-byte nonce. Returns
/// `(base64(ciphertext||tag), base64(nonce))`. The iOS side reconstructs a
/// CryptoKit `AES.GCM.SealedBox(nonce:, ciphertext: e[..<n-16], tag: e[n-16..])`.
fn encrypt(key_b64: &str, plaintext: &[u8]) -> anyhow::Result<(String, String)> {
    let key = B64
        .decode(key_b64)
        .map_err(|e| anyhow::anyhow!("bad enc_key base64: {e}"))?;
    if key.len() != 32 {
        anyhow::bail!("enc_key must be 32 bytes, got {}", key.len());
    }
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|e| anyhow::anyhow!("aes init: {e}"))?;
    let mut nonce_bytes = [0u8; 12];
    getrandom::getrandom(&mut nonce_bytes).map_err(|e| anyhow::anyhow!("rng: {e}"))?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| anyhow::anyhow!("aes encrypt: {e}"))?;
    Ok((B64.encode(ciphertext), B64.encode(nonce_bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_roundtrips_with_aes_gcm() {
        // 32-byte key, base64-encoded as the wire carries it.
        let key = [7u8; 32];
        let key_b64 = B64.encode(key);
        let (e_b64, n_b64) = encrypt(&key_b64, b"hello motif").unwrap();

        // Decrypt with the same primitive to prove tag layout (ct||tag).
        let cipher = Aes256Gcm::new_from_slice(&key).unwrap();
        let nonce_bytes = B64.decode(&n_b64).unwrap();
        let ct = B64.decode(&e_b64).unwrap();
        let pt = cipher
            .decrypt(Nonce::from_slice(&nonce_bytes), ct.as_ref())
            .unwrap();
        assert_eq!(pt, b"hello motif");
        assert_eq!(nonce_bytes.len(), 12);
    }

    #[test]
    fn encrypt_rejects_short_key() {
        let key_b64 = B64.encode([0u8; 16]);
        assert!(encrypt(&key_b64, b"x").is_err());
    }
}
