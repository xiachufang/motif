//! Authenticated WebSocket rendezvous relay core.
//!
//! An external HTTPS reverse proxy terminates WSS and forwards WebSocket
//! requests here. `motifd` connects to `/v2/accept` and authenticates its owner
//! with a JWT in the Upgrade request. Native clients connect to `/v2/connect`
//! without an account credential. Both sides send the
//! same opaque rendezvous token in their first binary message; the relay pairs
//! them, signals `PAIRED`, and forwards binary frames containing the existing
//! client↔motifd end-to-end TLS stream.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use bytes::Bytes;
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

/// First WebSocket binary message: `MRZV`, version, token.
pub const MAGIC: [u8; 4] = *b"MRZV";
pub const VERSION: u8 = 2;
pub const TOKEN_LEN: usize = 32;
pub const HELLO_LEN: usize = MAGIC.len() + 1 + TOKEN_LEN;
pub const CTRL_PAIRED: u8 = 0x10;

const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_WS_MESSAGE_BYTES: usize = 1024 * 1024;
const FORWARD_CHUNK_BYTES: usize = 16 * 1024;

pub type Token = [u8; TOKEN_LEN];

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RateConfig {
    pub client_to_server_bytes_per_sec: u64,
    pub server_to_client_bytes_per_sec: u64,
    pub burst_bytes: u64,
}

/// Simpler bandwidth shape used by plans. Upload is client -> motifd and
/// download is motifd -> client. Burst capacity is derived as one second of
/// traffic so deployments only have two numbers to tune.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BandwidthConfig {
    pub upload_bytes_per_sec: u64,
    pub download_bytes_per_sec: u64,
}

impl BandwidthConfig {
    fn validate(&self, name: &str) -> anyhow::Result<()> {
        if self.upload_bytes_per_sec == 0 || self.download_bytes_per_sec == 0 {
            anyhow::bail!("bandwidth for {name} must use positive upload/download rates");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanConfig {
    per_user: BandwidthConfig,
    #[serde(default)]
    total: Option<BandwidthConfig>,
}

impl RateConfig {
    fn validate(&self, subject: &str) -> anyhow::Result<()> {
        if self.client_to_server_bytes_per_sec == 0
            || self.server_to_client_bytes_per_sec == 0
            || self.burst_bytes == 0
        {
            anyhow::bail!("rate for {subject} must use positive byte rates and burst_bytes");
        }
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct JwtFileConfig {
    algorithm: String,
    issuer: String,
    audience: String,
    verification_key: PathBuf,
}

fn default_access_ttl_secs() -> u64 {
    7 * 24 * 60 * 60
}

fn default_refresh_ttl_secs() -> u64 {
    365 * 24 * 60 * 60
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct FreeIssuerFileConfig {
    signing_key: PathBuf,
    #[serde(default = "default_access_ttl_secs")]
    access_ttl_secs: u64,
    #[serde(default = "default_refresh_ttl_secs")]
    refresh_ttl_secs: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthFileConfig {
    jwt: JwtFileConfig,
    #[serde(default)]
    users: HashMap<String, RateConfig>,
    #[serde(default)]
    plans: HashMap<String, PlanConfig>,
    #[serde(default)]
    free_issuer: Option<FreeIssuerFileConfig>,
}

#[derive(Debug, Deserialize)]
struct Claims {
    sub: String,
    #[serde(default)]
    plan: Option<String>,
}

#[derive(Clone)]
pub struct AuthenticatedUser {
    pub subject: Arc<str>,
    limiter: Arc<UserLimiter>,
    global_limiter: Option<Arc<UserLimiter>>,
}

struct PlanRuntime {
    per_user: BandwidthConfig,
    global_limiter: Option<Arc<UserLimiter>>,
    users: Mutex<HashMap<String, Weak<UserLimiter>>>,
}

struct FreeIssuer {
    algorithm: Algorithm,
    encoding_key: EncodingKey,
    decoding_key: DecodingKey,
    issuer: String,
    access_audience: String,
    refresh_audience: String,
    access_ttl_secs: u64,
    refresh_ttl_secs: u64,
}

/// JWT verifier plus the authoritative local user→rate table.
pub struct Authenticator {
    decoding_key: DecodingKey,
    validation: Validation,
    users: HashMap<String, AuthenticatedUser>,
    plans: HashMap<String, PlanRuntime>,
    free_issuer: Option<Arc<FreeIssuer>>,
}

impl Authenticator {
    pub fn from_file(path: &Path) -> anyhow::Result<Self> {
        let raw =
            std::fs::read(path).with_context(|| format!("read auth config {}", path.display()))?;
        let mut cfg: AuthFileConfig = serde_json::from_slice(&raw)
            .with_context(|| format!("parse auth config {}", path.display()))?;
        if cfg.users.is_empty() && cfg.plans.is_empty() {
            anyhow::bail!("auth config must contain at least one user or plan");
        }

        if cfg.jwt.verification_key.is_relative() {
            let base = path.parent().unwrap_or_else(|| Path::new("."));
            cfg.jwt.verification_key = base.join(&cfg.jwt.verification_key);
        }
        let key = std::fs::read(&cfg.jwt.verification_key).with_context(|| {
            format!(
                "read JWT verification key {}",
                cfg.jwt.verification_key.display()
            )
        })?;
        let algorithm = parse_algorithm(&cfg.jwt.algorithm)?;
        let access_decoding_key = decoding_key(algorithm, &key)?;
        let free_issuer = if let Some(mut issuer) = cfg.free_issuer {
            if !cfg.plans.contains_key("free") {
                anyhow::bail!("free_issuer requires a plans.free bandwidth policy");
            }
            if issuer.access_ttl_secs == 0 || issuer.refresh_ttl_secs == 0 {
                anyhow::bail!("free_issuer token TTLs must be positive");
            }
            if issuer.signing_key.is_relative() {
                let base = path.parent().unwrap_or_else(|| Path::new("."));
                issuer.signing_key = base.join(&issuer.signing_key);
            }
            let signing_key = std::fs::read(&issuer.signing_key).with_context(|| {
                format!("read JWT signing key {}", issuer.signing_key.display())
            })?;
            Some(Arc::new(FreeIssuer {
                algorithm,
                encoding_key: encoding_key(algorithm, &signing_key)?,
                decoding_key: decoding_key(algorithm, &key)?,
                issuer: cfg.jwt.issuer.clone(),
                access_audience: cfg.jwt.audience.clone(),
                refresh_audience: format!("{}-refresh", cfg.jwt.audience),
                access_ttl_secs: issuer.access_ttl_secs,
                refresh_ttl_secs: issuer.refresh_ttl_secs,
            }))
        } else {
            None
        };
        Self::new_with_plans(
            algorithm,
            access_decoding_key,
            &cfg.jwt.issuer,
            &cfg.jwt.audience,
            cfg.users,
            cfg.plans,
            free_issuer,
        )
    }

    #[cfg(test)]
    fn new(
        algorithm: Algorithm,
        decoding_key: DecodingKey,
        issuer: &str,
        audience: &str,
        rates: HashMap<String, RateConfig>,
    ) -> anyhow::Result<Self> {
        Self::new_with_plans(
            algorithm,
            decoding_key,
            issuer,
            audience,
            rates,
            HashMap::new(),
            None,
        )
    }

    fn new_with_plans(
        algorithm: Algorithm,
        decoding_key: DecodingKey,
        issuer: &str,
        audience: &str,
        rates: HashMap<String, RateConfig>,
        plan_configs: HashMap<String, PlanConfig>,
        free_issuer: Option<Arc<FreeIssuer>>,
    ) -> anyhow::Result<Self> {
        let mut users = HashMap::with_capacity(rates.len());
        for (subject, rate) in rates {
            if subject.trim().is_empty() {
                anyhow::bail!("auth config contains an empty user subject");
            }
            rate.validate(&subject)?;
            users.insert(
                subject.clone(),
                AuthenticatedUser {
                    subject: Arc::from(subject),
                    limiter: Arc::new(UserLimiter::new(rate)),
                    global_limiter: None,
                },
            );
        }

        let mut plans = HashMap::with_capacity(plan_configs.len());
        for (name, cfg) in plan_configs {
            if name.trim().is_empty() {
                anyhow::bail!("auth config contains an empty plan name");
            }
            cfg.per_user.validate(&format!("plan {name}.per_user"))?;
            if let Some(total) = cfg.total {
                total.validate(&format!("plan {name}.total"))?;
            }
            plans.insert(
                name,
                PlanRuntime {
                    per_user: cfg.per_user,
                    global_limiter: cfg
                        .total
                        .map(|rate| Arc::new(UserLimiter::new_bandwidth(rate))),
                    users: Mutex::new(HashMap::new()),
                },
            );
        }

        let mut validation = Validation::new(algorithm);
        validation.set_issuer(&[issuer]);
        validation.set_audience(&[audience]);
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        validation.leeway = 30;

        Ok(Self {
            decoding_key,
            validation,
            users,
            plans,
            free_issuer,
        })
    }

    fn authenticate(&self, headers: &HeaderMap) -> anyhow::Result<AuthenticatedUser> {
        let token = bearer_token(headers)
            .ok_or_else(|| anyhow::anyhow!("Authorization must use Bearer"))?;
        let data = decode::<Claims>(token, &self.decoding_key, &self.validation)
            .context("JWT rejected")?;
        if let Some(user) = self.users.get(&data.claims.sub) {
            return Ok(user.clone());
        }
        let plan_name = data
            .claims
            .plan
            .ok_or_else(|| anyhow::anyhow!("JWT subject is not configured and has no plan"))?;
        let plan = self
            .plans
            .get(&plan_name)
            .ok_or_else(|| anyhow::anyhow!("JWT plan is not configured"))?;
        let limiter = {
            let mut users = plan.users.lock();
            users.retain(|_, limiter| limiter.strong_count() > 0);
            if let Some(limiter) = users.get(&data.claims.sub).and_then(Weak::upgrade) {
                limiter
            } else {
                let limiter = Arc::new(UserLimiter::new_bandwidth(plan.per_user));
                users.insert(data.claims.sub.clone(), Arc::downgrade(&limiter));
                limiter
            }
        };
        Ok(AuthenticatedUser {
            subject: Arc::from(data.claims.sub),
            limiter,
            global_limiter: plan.global_limiter.clone(),
        })
    }
}

fn parse_algorithm(value: &str) -> anyhow::Result<Algorithm> {
    match value {
        "HS256" => Ok(Algorithm::HS256),
        "RS256" => Ok(Algorithm::RS256),
        "ES256" => Ok(Algorithm::ES256),
        "EdDSA" => Ok(Algorithm::EdDSA),
        other => anyhow::bail!("unsupported JWT algorithm {other}"),
    }
}

fn decoding_key(algorithm: Algorithm, key: &[u8]) -> anyhow::Result<DecodingKey> {
    match algorithm {
        Algorithm::HS256 => Ok(DecodingKey::from_secret(trim_ascii(key))),
        Algorithm::RS256 => DecodingKey::from_rsa_pem(key).context("parse RSA public key"),
        Algorithm::ES256 => DecodingKey::from_ec_pem(key).context("parse EC public key"),
        Algorithm::EdDSA => DecodingKey::from_ed_pem(key).context("parse Ed25519 public key"),
        _ => unreachable!("algorithm allowlist handled above"),
    }
}

fn encoding_key(algorithm: Algorithm, key: &[u8]) -> anyhow::Result<EncodingKey> {
    match algorithm {
        Algorithm::HS256 => Ok(EncodingKey::from_secret(trim_ascii(key))),
        Algorithm::RS256 => EncodingKey::from_rsa_pem(key).context("parse RSA private key"),
        Algorithm::ES256 => EncodingKey::from_ec_pem(key).context("parse EC private key"),
        Algorithm::EdDSA => EncodingKey::from_ed_pem(key).context("parse Ed25519 private key"),
        _ => unreachable!("algorithm allowlist handled above"),
    }
}

fn trim_ascii(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|b| !b.is_ascii_whitespace())
        .unwrap_or(0);
    let end = bytes
        .iter()
        .rposition(|b| !b.is_ascii_whitespace())
        .map(|i| i + 1)
        .unwrap_or(start);
    &bytes[start..end]
}

#[derive(Serialize)]
struct AccessClaims<'a> {
    iss: &'a str,
    aud: &'a str,
    sub: &'a str,
    plan: &'static str,
    iat: u64,
    exp: u64,
    jti: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct RefreshClaims {
    iss: String,
    aud: String,
    sub: String,
    plan: String,
    token_use: String,
    iat: u64,
    exp: u64,
    jti: String,
}

#[derive(Serialize)]
struct InstallationTokenResponse {
    installation_id: String,
    access_token: String,
    access_expires_at: u64,
    refresh_token: String,
    refresh_expires_at: u64,
}

impl FreeIssuer {
    fn register(&self) -> anyhow::Result<InstallationTokenResponse> {
        let installation_id = format!("inst_{}", random_id()?);
        self.issue(&installation_id)
    }

    fn refresh(&self, token: &str) -> anyhow::Result<InstallationTokenResponse> {
        let mut validation = Validation::new(self.algorithm);
        validation.set_issuer(&[&self.issuer]);
        validation.set_audience(&[&self.refresh_audience]);
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        validation.leeway = 30;
        let claims = decode::<RefreshClaims>(token, &self.decoding_key, &validation)
            .context("refresh JWT rejected")?
            .claims;
        if claims.plan != "free" || claims.token_use != "refresh" {
            anyhow::bail!("refresh JWT has the wrong token type");
        }
        self.issue(&claims.sub)
    }

    fn issue(&self, installation_id: &str) -> anyhow::Result<InstallationTokenResponse> {
        let now = unix_time()?;
        let access_expires_at = now
            .checked_add(self.access_ttl_secs)
            .context("access token expiry overflow")?;
        let refresh_expires_at = now
            .checked_add(self.refresh_ttl_secs)
            .context("refresh token expiry overflow")?;
        let header = Header::new(self.algorithm);
        let access_token = encode(
            &header,
            &AccessClaims {
                iss: &self.issuer,
                aud: &self.access_audience,
                sub: installation_id,
                plan: "free",
                iat: now,
                exp: access_expires_at,
                jti: random_id()?,
            },
            &self.encoding_key,
        )
        .context("sign access JWT")?;
        let refresh_token = encode(
            &header,
            &RefreshClaims {
                iss: self.issuer.clone(),
                aud: self.refresh_audience.clone(),
                sub: installation_id.to_string(),
                plan: "free".to_string(),
                token_use: "refresh".to_string(),
                iat: now,
                exp: refresh_expires_at,
                jti: random_id()?,
            },
            &self.encoding_key,
        )
        .context("sign refresh JWT")?;
        Ok(InstallationTokenResponse {
            installation_id: installation_id.to_string(),
            access_token,
            access_expires_at,
            refresh_token,
            refresh_expires_at,
        })
    }
}

fn unix_time() -> anyhow::Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before Unix epoch")?
        .as_secs())
}

fn random_id() -> anyhow::Result<String> {
    let mut bytes = [0u8; 18];
    getrandom::getrandom(&mut bytes)
        .map_err(|error| anyhow::anyhow!("secure random generator failed: {error}"))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

pub struct HubConfig {
    pub park_ttl: Duration,
    pub keepalive: Duration,
}

impl Default for HubConfig {
    fn default() -> Self {
        Self {
            park_ttl: Duration::from_secs(3600),
            keepalive: Duration::from_secs(15),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Role {
    Accept,
    Connect,
}

struct Peer {
    socket: WebSocket,
    role: Role,
    user: Option<AuthenticatedUser>,
}

struct Waiter {
    tx: tokio::sync::oneshot::Sender<Peer>,
    since: Instant,
}

#[derive(Default)]
struct Waiters {
    accepts: VecDeque<Waiter>,
    connects: VecDeque<Waiter>,
}

impl Waiters {
    fn is_empty(&self) -> bool {
        self.accepts.is_empty() && self.connects.is_empty()
    }
}

pub struct Hub {
    inner: Mutex<HashMap<Token, Waiters>>,
    park_ttl: Duration,
    keepalive: Duration,
    auth: Authenticator,
}

impl Hub {
    pub fn new(cfg: HubConfig, auth: Authenticator) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(HashMap::new()),
            park_ttl: cfg.park_ttl,
            keepalive: cfg.keepalive,
            auth,
        })
    }

    /// Axum router served as HTTP/WebSocket behind the deployment's HTTPS
    /// reverse proxy. Also exposed directly for in-process protocol tests.
    pub fn router(self: &Arc<Self>) -> Router {
        Router::new()
            .route("/health", get(|| async { "ok" }))
            .route("/v1/free/installations", post(register_free_installation))
            .route("/v1/free/token", post(refresh_free_token))
            .route("/v2/accept", get(accept_upgrade))
            .route("/v2/connect", get(connect_upgrade))
            .with_state(Arc::clone(self))
    }

    pub fn spawn_reaper(self: &Arc<Self>) {
        let hub = Arc::clone(self);
        tokio::spawn(async move { hub.reap_loop().await });
    }

    async fn handle(
        self: Arc<Self>,
        socket: WebSocket,
        role: Role,
        user: Option<AuthenticatedUser>,
    ) {
        match read_hello(socket, role, user).await {
            Ok((token, peer)) => {
                self.pair_or_park(token, peer).await;
            }
            Err(e) => {
                tracing::debug!(error = %e, ?role, "rzv websocket ended before pairing");
            }
        }
    }

    async fn pair_or_park(self: &Arc<Self>, token: Token, peer: Peer) {
        let role = peer.role;
        let rx = {
            let mut map = self.inner.lock();
            let waiters = map.entry(token).or_default();
            let opposite = match role {
                Role::Accept => &mut waiters.connects,
                Role::Connect => &mut waiters.accepts,
            };

            let mut handed = Some(peer);
            while let Some(waiter) = opposite.pop_front() {
                match waiter.tx.send(handed.take().expect("peer present")) {
                    Ok(()) => break,
                    Err(returned) => handed = Some(returned),
                }
            }

            match handed {
                None => {
                    if waiters.is_empty() {
                        map.remove(&token);
                    }
                    None
                }
                Some(peer) => {
                    let (tx, rx) = tokio::sync::oneshot::channel();
                    let queue = match role {
                        Role::Accept => &mut waiters.accepts,
                        Role::Connect => &mut waiters.connects,
                    };
                    queue.push_back(Waiter {
                        tx,
                        since: Instant::now(),
                    });
                    Some((peer, rx))
                }
            }
        };

        if let Some((peer, rx)) = rx {
            park(peer, rx, self.keepalive).await;
        }
    }

    async fn reap_loop(self: Arc<Self>) {
        let mut tick = tokio::time::interval(Duration::from_secs(30));
        loop {
            tick.tick().await;
            let now = Instant::now();
            let ttl = self.park_ttl;
            let mut map = self.inner.lock();
            map.retain(|_, waiters| {
                let keep = |w: &Waiter| !w.tx.is_closed() && now.duration_since(w.since) < ttl;
                waiters.accepts.retain(keep);
                waiters.connects.retain(keep);
                !waiters.is_empty()
            });
        }
    }

    pub fn parked_tokens(&self) -> usize {
        self.inner.lock().len()
    }
}

async fn register_free_installation(State(hub): State<Arc<Hub>>) -> Response {
    let Some(issuer) = &hub.auth.free_issuer else {
        return (StatusCode::NOT_FOUND, "free relay registration is disabled").into_response();
    };
    match issuer.register() {
        Ok(tokens) => (StatusCode::CREATED, Json(tokens)).into_response(),
        Err(error) => {
            tracing::error!(%error, "issue free relay credentials");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                "could not issue credentials",
            )
                .into_response()
        }
    }
}

async fn refresh_free_token(State(hub): State<Arc<Hub>>, headers: HeaderMap) -> Response {
    let Some(issuer) = &hub.auth.free_issuer else {
        return (StatusCode::NOT_FOUND, "free relay registration is disabled").into_response();
    };
    let Some(token) = bearer_token(&headers) else {
        return (StatusCode::UNAUTHORIZED, "invalid refresh token").into_response();
    };
    match issuer.refresh(token) {
        Ok(tokens) => (StatusCode::OK, Json(tokens)).into_response(),
        Err(error) => {
            tracing::warn!(%error, "free relay refresh rejected");
            (StatusCode::UNAUTHORIZED, "invalid refresh token").into_response()
        }
    }
}

fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

async fn accept_upgrade(
    State(hub): State<Arc<Hub>>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    let user = match hub.auth.authenticate(&headers) {
        Ok(user) => user,
        Err(e) => {
            tracing::warn!(error = %e, "rzv accept JWT rejected");
            return (StatusCode::UNAUTHORIZED, "invalid rendezvous JWT").into_response();
        }
    };
    ws.max_message_size(MAX_WS_MESSAGE_BYTES)
        .max_frame_size(MAX_WS_MESSAGE_BYTES)
        .on_upgrade(move |socket| Arc::clone(&hub).handle(socket, Role::Accept, Some(user)))
}

async fn connect_upgrade(State(hub): State<Arc<Hub>>, ws: WebSocketUpgrade) -> Response {
    ws.max_message_size(MAX_WS_MESSAGE_BYTES)
        .max_frame_size(MAX_WS_MESSAGE_BYTES)
        .on_upgrade(move |socket| Arc::clone(&hub).handle(socket, Role::Connect, None))
}

async fn read_hello(
    mut socket: WebSocket,
    role: Role,
    user: Option<AuthenticatedUser>,
) -> anyhow::Result<(Token, Peer)> {
    let token = tokio::time::timeout(HELLO_TIMEOUT, async {
        loop {
            match socket.recv().await {
                Some(Ok(Message::Binary(frame))) => return parse_hello(&frame),
                Some(Ok(Message::Ping(payload))) => socket.send(Message::Pong(payload)).await?,
                Some(Ok(Message::Pong(_))) => {}
                Some(Ok(Message::Close(_))) | None => anyhow::bail!("websocket closed"),
                Some(Ok(Message::Text(_))) => anyhow::bail!("HELLO must be binary"),
                Some(Err(e)) => return Err(e.into()),
            }
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("HELLO timed out"))??;
    Ok((token, Peer { socket, role, user }))
}

pub fn build_hello(token: &Token) -> Vec<u8> {
    let mut frame = Vec::with_capacity(HELLO_LEN);
    frame.extend_from_slice(&MAGIC);
    frame.push(VERSION);
    frame.extend_from_slice(token);
    frame
}

pub fn parse_hello(frame: &[u8]) -> anyhow::Result<Token> {
    if frame.len() != HELLO_LEN {
        anyhow::bail!("HELLO must be {HELLO_LEN} bytes, got {}", frame.len());
    }
    if frame[..MAGIC.len()] != MAGIC {
        anyhow::bail!("bad HELLO magic");
    }
    if frame[MAGIC.len()] != VERSION {
        anyhow::bail!("unsupported HELLO version {}", frame[MAGIC.len()]);
    }
    let mut token = [0u8; TOKEN_LEN];
    token.copy_from_slice(&frame[MAGIC.len() + 1..]);
    Ok(token)
}

async fn park(mut peer: Peer, mut rx: tokio::sync::oneshot::Receiver<Peer>, keepalive: Duration) {
    let mut tick = tokio::time::interval(if keepalive.is_zero() {
        Duration::from_secs(3600)
    } else {
        keepalive
    });
    tick.tick().await;

    loop {
        tokio::select! {
            partner = &mut rx => {
                if let Ok(partner) = partner {
                    splice(peer, partner, keepalive).await;
                }
                return;
            }
            msg = peer.socket.recv() => match msg {
                Some(Ok(Message::Ping(payload))) => {
                    if peer.socket.send(Message::Pong(payload)).await.is_err() { return; }
                }
                Some(Ok(Message::Pong(_))) => {}
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return,
                Some(Ok(Message::Binary(_))) | Some(Ok(Message::Text(_))) => {
                    let _ = peer.socket.send(Message::Close(None)).await;
                    return;
                }
            },
            _ = tick.tick(), if !keepalive.is_zero() => {
                if peer.socket.send(Message::Ping(Bytes::new())).await.is_err() { return; }
            }
        }
    }
}

async fn splice(a: Peer, b: Peer, keepalive: Duration) {
    let (mut accept, mut connect) = match (a.role, b.role) {
        (Role::Accept, Role::Connect) => (a, b),
        (Role::Connect, Role::Accept) => (b, a),
        _ => return,
    };
    let Some(user) = accept.user.take() else {
        tracing::warn!("rzv paired accept without authenticated user");
        return;
    };

    if accept
        .socket
        .send(Message::Binary(Bytes::from_static(&[CTRL_PAIRED])))
        .await
        .is_err()
        || connect
            .socket
            .send(Message::Binary(Bytes::from_static(&[CTRL_PAIRED])))
            .await
            .is_err()
    {
        return;
    }

    let accept_socket = accept.socket;
    let connect_socket = connect.socket;
    let (accept_tx, accept_rx) = accept_socket.split();
    let (connect_tx, connect_rx) = connect_socket.split();

    let c2s = pump(
        connect_rx,
        accept_tx,
        DirectionLimiters {
            user: Arc::clone(&user.limiter.client_to_server),
            global: user
                .global_limiter
                .as_ref()
                .map(|limiter| Arc::clone(&limiter.client_to_server)),
        },
        keepalive,
    );
    let s2c = pump(
        accept_rx,
        connect_tx,
        DirectionLimiters {
            user: Arc::clone(&user.limiter.server_to_client),
            global: user
                .global_limiter
                .as_ref()
                .map(|limiter| Arc::clone(&limiter.server_to_client)),
        },
        keepalive,
    );
    let (c2s, s2c) = tokio::join!(c2s, s2c);
    tracing::debug!(
        subject = %user.subject,
        client_to_server = c2s.unwrap_or_default(),
        server_to_client = s2c.unwrap_or_default(),
        "rzv websocket splice closed"
    );
}

async fn pump(
    mut input: SplitStream<WebSocket>,
    mut output: SplitSink<WebSocket, Message>,
    limiters: DirectionLimiters,
    keepalive: Duration,
) -> anyhow::Result<u64> {
    let mut total = 0u64;
    let mut tick = tokio::time::interval(if keepalive.is_zero() {
        Duration::from_secs(3600)
    } else {
        keepalive
    });
    tick.tick().await;

    loop {
        tokio::select! {
            msg = input.next() => match msg {
                Some(Ok(Message::Binary(payload))) => {
                    let mut offset = 0;
                    while offset < payload.len() {
                        let n = limiters.max_chunk(payload.len() - offset);
                        limiters.consume(n).await;
                        output
                            .send(Message::Binary(payload.slice(offset..offset + n)))
                            .await?;
                        offset += n;
                        total += n as u64;
                    }
                }
                Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => {
                    // tungstenite queues the required PONG on the shared socket;
                    // the next sink flush (including our periodic PING) sends it.
                }
                Some(Ok(Message::Close(frame))) => {
                    let _ = output.send(Message::Close(frame)).await;
                    return Ok(total);
                }
                Some(Ok(Message::Text(_))) => anyhow::bail!("text frame after pairing"),
                Some(Err(e)) => return Err(e.into()),
                None => return Ok(total),
            },
            _ = tick.tick(), if !keepalive.is_zero() => {
                output.send(Message::Ping(Bytes::new())).await?;
            }
        }
    }
}

struct DirectionLimiters {
    user: Arc<TokenBucket>,
    global: Option<Arc<TokenBucket>>,
}

impl DirectionLimiters {
    fn max_chunk(&self, remaining: usize) -> usize {
        let user = self.user.max_chunk(remaining);
        self.global
            .as_ref()
            .map_or(user, |global| global.max_chunk(user))
    }

    async fn consume(&self, bytes: usize) {
        // Consume the shared bucket first. Sequential acquisition can be a
        // little conservative under saturation but never lets either the
        // per-installation or global plan limit be exceeded.
        if let Some(global) = &self.global {
            global.consume(bytes).await;
        }
        self.user.consume(bytes).await;
    }
}

struct UserLimiter {
    client_to_server: Arc<TokenBucket>,
    server_to_client: Arc<TokenBucket>,
}

impl UserLimiter {
    fn new(cfg: RateConfig) -> Self {
        Self {
            client_to_server: Arc::new(TokenBucket::new(
                cfg.client_to_server_bytes_per_sec,
                cfg.burst_bytes,
            )),
            server_to_client: Arc::new(TokenBucket::new(
                cfg.server_to_client_bytes_per_sec,
                cfg.burst_bytes,
            )),
        }
    }

    fn new_bandwidth(cfg: BandwidthConfig) -> Self {
        Self {
            client_to_server: Arc::new(TokenBucket::new(
                cfg.upload_bytes_per_sec,
                cfg.upload_bytes_per_sec.max(FORWARD_CHUNK_BYTES as u64),
            )),
            server_to_client: Arc::new(TokenBucket::new(
                cfg.download_bytes_per_sec,
                cfg.download_bytes_per_sec.max(FORWARD_CHUNK_BYTES as u64),
            )),
        }
    }
}

struct BucketState {
    tokens: f64,
    updated: tokio::time::Instant,
}

struct TokenBucket {
    rate: f64,
    capacity: f64,
    state: tokio::sync::Mutex<BucketState>,
}

impl TokenBucket {
    fn new(bytes_per_sec: u64, burst_bytes: u64) -> Self {
        Self {
            rate: bytes_per_sec as f64,
            capacity: burst_bytes as f64,
            state: tokio::sync::Mutex::new(BucketState {
                tokens: burst_bytes as f64,
                updated: tokio::time::Instant::now(),
            }),
        }
    }

    fn max_chunk(&self, remaining: usize) -> usize {
        remaining
            .min(FORWARD_CHUNK_BYTES)
            .min(self.capacity as usize)
            .max(1)
    }

    async fn consume(&self, bytes: usize) {
        let need = bytes as f64;
        loop {
            let wait = {
                let mut state = self.state.lock().await;
                let now = tokio::time::Instant::now();
                let elapsed = now.duration_since(state.updated).as_secs_f64();
                state.tokens = (state.tokens + elapsed * self.rate).min(self.capacity);
                state.updated = now;
                if state.tokens >= need {
                    state.tokens -= need;
                    return;
                }
                Duration::from_secs_f64((need - state.tokens) / self.rate)
            };
            tokio::time::sleep(wait).await;
        }
    }
}

/// Lightweight liveness check used by the container. The runtime probe verifies
/// the internal HTTP/WebSocket listener is accepting connections.
pub async fn health_check(addr: &str, timeout: Duration) -> anyhow::Result<()> {
    tokio::time::timeout(timeout, tokio::net::TcpStream::connect(addr))
        .await
        .map_err(|_| anyhow::anyhow!("health probe timed out after {timeout:?}"))??;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{encode, EncodingKey, Header};
    use serde::Serialize;

    #[test]
    fn hello_roundtrip() {
        let token = [7u8; TOKEN_LEN];
        assert_eq!(parse_hello(&build_hello(&token)).unwrap(), token);
        assert!(parse_hello(&build_hello(&token)[..HELLO_LEN - 1]).is_err());
    }

    #[derive(Serialize)]
    struct TestClaims<'a> {
        iss: &'a str,
        aud: &'a str,
        sub: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        plan: Option<&'a str>,
        exp: usize,
    }

    #[test]
    fn jwt_maps_to_configured_user() {
        let rates = HashMap::from([(
            "user-1".to_string(),
            RateConfig {
                client_to_server_bytes_per_sec: 100,
                server_to_client_bytes_per_sec: 200,
                burst_bytes: 10,
            },
        )]);
        let auth = Authenticator::new(
            Algorithm::HS256,
            DecodingKey::from_secret(b"test secret"),
            "issuer",
            "relay",
            rates,
        )
        .unwrap();
        let jwt = encode(
            &Header::new(Algorithm::HS256),
            &TestClaims {
                iss: "issuer",
                aud: "relay",
                sub: "user-1",
                plan: None,
                exp: 4_102_444_800,
            },
            &EncodingKey::from_secret(b"test secret"),
        )
        .unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            format!("Bearer {jwt}").parse().unwrap(),
        );
        let first = auth.authenticate(&headers).unwrap();
        let second = auth.authenticate(&headers).unwrap();
        assert_eq!(&*first.subject, "user-1");
        assert!(Arc::ptr_eq(&first.limiter, &second.limiter));
    }

    #[test]
    fn plan_jwt_gets_dynamic_user_and_shared_global_limiters() {
        let auth = Authenticator::new_with_plans(
            Algorithm::HS256,
            DecodingKey::from_secret(b"test secret"),
            "issuer",
            "relay",
            HashMap::new(),
            HashMap::from([(
                "free".to_string(),
                PlanConfig {
                    per_user: BandwidthConfig {
                        upload_bytes_per_sec: 100,
                        download_bytes_per_sec: 200,
                    },
                    total: Some(BandwidthConfig {
                        upload_bytes_per_sec: 1000,
                        download_bytes_per_sec: 2000,
                    }),
                },
            )]),
            None,
        )
        .unwrap();
        let token = |sub: &str| {
            encode(
                &Header::new(Algorithm::HS256),
                &TestClaims {
                    iss: "issuer",
                    aud: "relay",
                    sub,
                    plan: Some("free"),
                    exp: 4_102_444_800,
                },
                &EncodingKey::from_secret(b"test secret"),
            )
            .unwrap()
        };
        let authenticate = |jwt: String| {
            let mut headers = HeaderMap::new();
            headers.insert(
                header::AUTHORIZATION,
                format!("Bearer {jwt}").parse().unwrap(),
            );
            auth.authenticate(&headers).unwrap()
        };

        let first = authenticate(token("installation-1"));
        let same = authenticate(token("installation-1"));
        let other = authenticate(token("installation-2"));
        assert!(Arc::ptr_eq(&first.limiter, &same.limiter));
        assert!(!Arc::ptr_eq(&first.limiter, &other.limiter));
        assert!(Arc::ptr_eq(
            first.global_limiter.as_ref().unwrap(),
            other.global_limiter.as_ref().unwrap()
        ));
    }

    #[test]
    fn free_issuer_rotates_refresh_and_issues_plan_claim() {
        let issuer = FreeIssuer {
            algorithm: Algorithm::HS256,
            encoding_key: EncodingKey::from_secret(b"test secret"),
            decoding_key: DecodingKey::from_secret(b"test secret"),
            issuer: "issuer".into(),
            access_audience: "relay".into(),
            refresh_audience: "relay-refresh".into(),
            access_ttl_secs: 600,
            refresh_ttl_secs: 3600,
        };
        let registered = issuer.register().unwrap();
        let refreshed = issuer.refresh(&registered.refresh_token).unwrap();
        assert_eq!(refreshed.installation_id, registered.installation_id);
        assert_ne!(refreshed.refresh_token, registered.refresh_token);

        let mut validation = Validation::new(Algorithm::HS256);
        validation.set_issuer(&["issuer"]);
        validation.set_audience(&["relay"]);
        let access = decode::<Claims>(
            &refreshed.access_token,
            &DecodingKey::from_secret(b"test secret"),
            &validation,
        )
        .unwrap();
        assert_eq!(access.claims.plan.as_deref(), Some("free"));
    }

    #[tokio::test(start_paused = true)]
    async fn token_bucket_waits_after_burst() {
        let bucket = Arc::new(TokenBucket::new(100, 10));
        bucket.consume(10).await;
        let pending = {
            let bucket = Arc::clone(&bucket);
            tokio::spawn(async move { bucket.consume(10).await })
        };
        tokio::task::yield_now().await;
        assert!(!pending.is_finished());
        tokio::time::advance(Duration::from_millis(100)).await;
        pending.await.unwrap();
    }
}
