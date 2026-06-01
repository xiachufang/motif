//! Motif APNs push relay.
//!
//! Holds the APNs `.p8` signing key (which must never ship in motifd or the
//! iOS app) and forwards **encrypted** notification payloads from self-hosted
//! motifd instances to Apple. It signs an ES256 provider JWT and POSTs to
//! APNs over HTTP/2.
//!
//! Contract with motifd (`crates/motif-server/src/relay.rs`):
//!   POST <relay-url>  body: {"device_token","environment","e","n"}
//!     e = base64(ciphertext‖16-byte GCM tag), n = base64(12-byte nonce)
//!   Response: 200 ok · 410 Gone => motifd prunes the token · 5xx => transient.
//!
//! The relay only ever sees ciphertext (`e`/`n`) — content is end-to-end
//! encrypted between motifd and the device's Notification Service Extension.
//!
//! Security posture: there is intentionally no shared auth secret with motifd
//! (motifd is open-source; a baked-in secret would leak). Abuse is bounded by
//! (a) device tokens being capabilities a caller must already know, (b)
//! per-token rate limiting here, and (c) E2E encryption — a forged push without
//! the device key only yields the undecryptable "🔒 New notification"
//! placeholder. Operators wanting more can front the relay with an IP allowlist.
//!
//! TLS: like motifd, the relay does not terminate TLS — listen on loopback /
//! a trusted segment and front it with a TLS-terminating proxy. motifd's client
//! accepts http or https URLs.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use bytes::Bytes;
use clap::Parser;
use http_body_util::{BodyExt, Full};
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

#[derive(Parser, Debug)]
#[command(name = "motif-push-relay", version, about = "Motif APNs push relay")]
struct Args {
    /// Listen address (plain HTTP; front with a TLS proxy).
    #[arg(long, default_value = "127.0.0.1:8088")]
    listen: SocketAddr,

    /// Path to the APNs auth key (.p8, PKCS#8 EC PEM).
    #[arg(long, env = "APNS_KEY_PATH")]
    apns_key_path: PathBuf,

    /// APNs Key ID (the 10-char id of the .p8).
    #[arg(long, env = "APNS_KEY_ID")]
    apns_key_id: String,

    /// Apple Developer Team ID.
    #[arg(long, env = "APNS_TEAM_ID")]
    apns_team_id: String,

    /// APNs topic — the app bundle id.
    #[arg(long, env = "APNS_TOPIC", default_value = "io.allsunday.motif")]
    apns_topic: String,

    /// Max pushes accepted per device token per 60s window.
    #[arg(long, default_value_t = 30)]
    rate_limit_per_min: u32,

    #[arg(long, env = "RELAY_LOG", default_value = "info")]
    log: String,
}

// ─────────────────────────── APNs JWT signer ───────────────────────────

#[derive(Serialize)]
struct Claims {
    iss: String,
    iat: u64,
}

/// Signs + caches the APNs provider JWT. Apple rejects tokens regenerated too
/// often and expects refresh within 20–60 min, so we reuse one for ~45 min.
struct Signer {
    key: EncodingKey,
    header: Header,
    team_id: String,
    cache: Mutex<Option<(String, Instant)>>,
}

impl Signer {
    fn new(key_pem: &[u8], key_id: String, team_id: String) -> anyhow::Result<Self> {
        let key = EncodingKey::from_ec_pem(key_pem)
            .context("parse APNs .p8 (expected PKCS#8 EC PEM)")?;
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(key_id);
        Ok(Self {
            key,
            header,
            team_id,
            cache: Mutex::new(None),
        })
    }

    fn token(&self) -> anyhow::Result<String> {
        let mut g = self.cache.lock();
        if let Some((tok, made)) = g.as_ref() {
            if made.elapsed() < Duration::from_secs(45 * 60) {
                return Ok(tok.clone());
            }
        }
        let claims = Claims {
            iss: self.team_id.clone(),
            iat: now_secs(),
        };
        let tok = jsonwebtoken::encode(&self.header, &claims, &self.key)
            .context("sign APNs JWT")?;
        *g = Some((tok.clone(), Instant::now()));
        Ok(tok)
    }
}

// ─────────────────────────── rate limiter ───────────────────────────

/// Per-token sliding-window limiter. Map grows with distinct tokens seen in the
/// last window; for a personal relay this is tiny. A periodic sweep drops idle
/// entries.
struct Limiter {
    max_per_min: u32,
    hits: Mutex<HashMap<String, Vec<Instant>>>,
}

impl Limiter {
    fn allow(&self, token: &str) -> bool {
        let now = Instant::now();
        let mut g = self.hits.lock();
        let v = g.entry(token.to_string()).or_default();
        v.retain(|t| now.duration_since(*t) < Duration::from_secs(60));
        if v.len() as u32 >= self.max_per_min {
            return false;
        }
        v.push(now);
        true
    }

    fn sweep(&self) {
        let now = Instant::now();
        let mut g = self.hits.lock();
        g.retain(|_, v| {
            v.retain(|t| now.duration_since(*t) < Duration::from_secs(60));
            !v.is_empty()
        });
    }
}

// ─────────────────────────── app state ───────────────────────────

type HttpsClient = Client<hyper_rustls::HttpsConnector<HttpConnector>, Full<Bytes>>;

#[derive(Clone)]
struct AppState {
    signer: Arc<Signer>,
    client: HttpsClient,
    topic: Arc<String>,
    limiter: Arc<Limiter>,
}

#[derive(Deserialize)]
struct PushReq {
    device_token: String,
    #[serde(default)]
    environment: Option<String>,
    /// base64 ciphertext‖tag
    e: String,
    /// base64 nonce
    n: String,
}

#[derive(Clone, Copy)]
enum Env {
    Sandbox,
    Production,
}

impl Env {
    fn host(self) -> &'static str {
        match self {
            Env::Sandbox => "api.sandbox.push.apple.com",
            Env::Production => "api.push.apple.com",
        }
    }
}

enum Outcome {
    Ok,
    /// Token invalid for this environment — worth trying the other env.
    BadToken,
    /// Token no longer registered — prune.
    Unregistered,
    /// Transient / config error.
    Error,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    tracing_subscriber::fmt()
        .with_env_filter(args.log.clone())
        .init();

    let pem = std::fs::read(&args.apns_key_path)
        .with_context(|| format!("read --apns-key-path {}", args.apns_key_path.display()))?;
    let signer = Arc::new(Signer::new(&pem, args.apns_key_id.clone(), args.apns_team_id.clone())?);
    // Validate signing up front so misconfig fails at startup, not first push.
    signer.token().context("initial APNs JWT sign failed")?;
    tracing::info!(
        key_id = %args.apns_key_id,
        team = %args.apns_team_id,
        topic = %args.apns_topic,
        "APNs signer ready",
    );

    let https = hyper_rustls::HttpsConnectorBuilder::new()
        .with_webpki_roots()
        .https_only()
        .enable_http2()
        .build();
    let client: HttpsClient = Client::builder(TokioExecutor::new())
        .http2_only(true)
        .build(https);

    let limiter = Arc::new(Limiter {
        max_per_min: args.rate_limit_per_min,
        hits: Mutex::new(HashMap::new()),
    });

    // Periodic sweep so the limiter map doesn't grow unbounded.
    {
        let limiter = limiter.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(120)).await;
                limiter.sweep();
            }
        });
    }

    let state = AppState {
        signer,
        client,
        topic: Arc::new(args.apns_topic),
        limiter,
    };

    let app = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/v1/push", post(push))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(args.listen)
        .await
        .with_context(|| format!("bind {}", args.listen))?;
    tracing::info!(addr = %args.listen, "motif-push-relay listening");
    axum::serve(listener, app).await.context("serve")?;
    Ok(())
}

async fn push(State(st): State<AppState>, Json(req): Json<PushReq>) -> StatusCode {
    if !st.limiter.allow(&req.device_token) {
        return StatusCode::TOO_MANY_REQUESTS;
    }

    let payload = build_apns_payload(&req.e, &req.n);

    // Try the hinted environment first; on BadToken, try the other (the token's
    // APNs world can disagree with the client's hint).
    let order = match req.environment.as_deref() {
        Some("production") => [Env::Production, Env::Sandbox],
        _ => [Env::Sandbox, Env::Production],
    };

    let mut saw_bad_token = false;
    for env in order {
        match send_apns(&st, env, &req.device_token, &payload).await {
            Outcome::Ok => return StatusCode::OK,
            Outcome::Unregistered => return StatusCode::GONE,
            Outcome::BadToken => {
                saw_bad_token = true;
                continue;
            }
            Outcome::Error => return StatusCode::BAD_GATEWAY,
        }
    }
    // Bad in every environment → tell motifd to prune.
    if saw_bad_token {
        StatusCode::GONE
    } else {
        StatusCode::BAD_GATEWAY
    }
}

fn build_apns_payload(e: &str, n: &str) -> Vec<u8> {
    // Placeholder alert shown if the Notification Service Extension can't run /
    // decrypt; mutable-content:1 is required for the extension to fire.
    serde_json::to_vec(&serde_json::json!({
        "aps": {
            "alert": { "body": "🔒 New notification" },
            "mutable-content": 1,
            "sound": "default",
            "interruption-level": "active"
        },
        "e": e,
        "n": n
    }))
    .unwrap_or_default()
}

async fn send_apns(st: &AppState, env: Env, token: &str, payload: &[u8]) -> Outcome {
    let jwt = match st.signer.token() {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("JWT sign failed: {e}");
            return Outcome::Error;
        }
    };
    let uri = format!("https://{}/3/device/{}", env.host(), token);
    let req = match http::Request::builder()
        .method(http::Method::POST)
        .uri(&uri)
        .header(http::header::AUTHORIZATION, format!("bearer {jwt}"))
        .header("apns-topic", st.topic.as_str())
        .header("apns-push-type", "alert")
        .header("apns-priority", "10")
        .body(Full::new(Bytes::copy_from_slice(payload)))
    {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("build APNs request: {e}");
            return Outcome::Error;
        }
    };

    let resp = match st.client.request(req).await {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("APNs transport error ({}): {e}", env.host());
            return Outcome::Error;
        }
    };
    let status = resp.status();
    let body = resp
        .into_body()
        .collect()
        .await
        .map(|b| b.to_bytes())
        .unwrap_or_default();

    match status.as_u16() {
        200 => Outcome::Ok,
        410 => Outcome::Unregistered, // device no longer registered
        400 => {
            let reason = apns_reason(&body);
            tracing::info!("APNs 400 ({}): {reason}", env.host());
            if reason == "BadDeviceToken" {
                Outcome::BadToken
            } else {
                Outcome::Error
            }
        }
        403 => {
            // Almost always a provider-token / signing misconfig.
            tracing::error!("APNs 403 ({}): {}", env.host(), apns_reason(&body));
            Outcome::Error
        }
        other => {
            tracing::warn!("APNs {other} ({}): {}", env.host(), apns_reason(&body));
            Outcome::Error
        }
    }
}

fn apns_reason(body: &[u8]) -> String {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("reason").and_then(|r| r.as_str().map(String::from)))
        .unwrap_or_else(|| "(no reason)".into())
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apns_payload_has_mutable_content_and_ciphertext() {
        let raw = build_apns_payload("CIPHER", "NONCE");
        let v: serde_json::Value = serde_json::from_slice(&raw).unwrap();
        assert_eq!(v["aps"]["mutable-content"], 1);
        assert_eq!(v["e"], "CIPHER");
        assert_eq!(v["n"], "NONCE");
        assert!(v["aps"]["alert"]["body"].is_string());
    }

    #[test]
    fn apns_reason_parses() {
        assert_eq!(apns_reason(br#"{"reason":"BadDeviceToken"}"#), "BadDeviceToken");
        assert_eq!(apns_reason(b"not json"), "(no reason)");
    }

    #[test]
    fn limiter_caps_per_token() {
        let lim = Limiter {
            max_per_min: 2,
            hits: Mutex::new(HashMap::new()),
        };
        assert!(lim.allow("a"));
        assert!(lim.allow("a"));
        assert!(!lim.allow("a")); // 3rd within the window is rejected
        assert!(lim.allow("b")); // independent per token
    }
}


#[cfg(test)]
mod genkey_tmp {
    #[test]
    fn dump_key() {
        use jsonwebtoken::ring::{rand, signature};
        let rng = rand::SystemRandom::new();
        let doc = signature::EcdsaKeyPair::generate_pkcs8(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        std::fs::write("/tmp/key.der", doc.as_ref()).unwrap();
    }
}
