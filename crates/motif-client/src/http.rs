//! `POST /rpc/<method>` HTTP RPC client.
//!
//! Uses hyper 1.x http1 directly so we can run the request over any
//! `AsyncRead + AsyncWrite` (plain TCP, tsnet socket, future wrappers).
//! One connection per request right now — pooling is a follow-up; the
//! head-of-line fix the new protocol exists to deliver doesn't need
//! pooling, since each RPC opens its own TCP socket.
//!
//! ## Surface
//!
//! [`HttpRpc::call(method, params)`] mirrors the old `Client::call` —
//! serialize params, POST, decode result. [`HttpRpc::attach`] is the
//! one method that snaps the session_id off the response header and
//! stashes it on the client for subsequent calls.
//!
//! ## Errors
//!
//! Server returns 4xx + JSON error envelope (see
//! `crates/motif-server/src/http_rpc.rs::err_response`). The decoder
//! reproduces that error shape as `RpcError`; HTTP-level errors (no
//! socket, EOF mid-headers) surface as `anyhow::Error`.

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context};
use bytes::Bytes;
use http::{HeaderValue, Method, Request, StatusCode, Uri};
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use motif_proto::error::RpcError;
use serde::{de::DeserializeOwned, Serialize};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;

/// Custom HTTP header used to pin a session_id across requests.
/// Lowercase per HTTP/2 conventions; hyper preserves case but server
/// compares case-insensitively via `axum::http::HeaderMap`.
pub const SESSION_HEADER: &str = "x-motif-session";

/// Type-erased duplex socket. Boxed so factories can return either a
/// `TcpStream` or whatever `motif_net::dial` produced.
pub type HttpStream = Pin<Box<dyn AsyncReadWrite + Send>>;
pub trait AsyncReadWrite: AsyncRead + AsyncWrite + Unpin {}
impl<T: AsyncRead + AsyncWrite + Unpin + ?Sized> AsyncReadWrite for T {}

/// Future-returning factory. Closure-based to avoid the `async_trait`
/// dependency — the trait surface is tiny (one method) so manual
/// boxing keeps the API surface clean. Each call to [`HttpRpc::call`]
/// asks the factory for one fresh stream.
pub type DialFuture = Pin<Box<dyn Future<Output = anyhow::Result<HttpStream>> + Send>>;
pub type StreamFactory = Arc<dyn Fn() -> DialFuture + Send + Sync>;

/// Plain-TCP factory: re-dials `host:port` each call. Trivial baseline
/// used by `HttpRpc::connect_tcp`.
pub fn tcp_factory(addr: impl Into<String>) -> StreamFactory {
    let addr = addr.into();
    Arc::new(move || {
        let addr = addr.clone();
        Box::pin(async move {
            let stream = TcpStream::connect(&addr)
                .await
                .with_context(|| format!("dial {}", addr))?;
            // nodelay off (default) since RPC bodies are small and we don't
            // mind the OS coalescing — keeps writes from fragmenting on the
            // wire when params + headers fit one segment together.
            Ok(Box::pin(stream) as HttpStream)
        })
    })
}

pub struct HttpRpc {
    factory: StreamFactory,
    /// Server authority used in HTTP `Host` header / `:authority`.
    authority: String,
    /// Bearer token, prebuilt as a HeaderValue once at construction
    /// time so each call doesn't re-allocate.
    auth: HeaderValue,
    /// Session id minted by `session.attach`. Set by [`HttpRpc::attach`]
    /// and echoed on subsequent calls via `X-Motif-Session`. `None`
    /// means "not attached yet" — only session.list / .create / .attach
    /// can succeed in that state.
    session_id: Mutex<Option<String>>,
}

impl HttpRpc {
    pub fn new(factory: StreamFactory, authority: String, token: &str) -> anyhow::Result<Self> {
        let auth = HeaderValue::from_str(&format!("Bearer {token}"))
            .map_err(|e| anyhow!("invalid bearer token: {e}"))?;
        Ok(Self {
            factory,
            authority,
            auth,
            session_id: Mutex::new(None),
        })
    }

    /// Convenience constructor for the plain-TCP path. Parses
    /// `http://host:port` to derive both the factory and the
    /// authority header.
    pub fn connect_tcp(url: &str, token: &str) -> anyhow::Result<Self> {
        let parsed: Uri = url.parse().with_context(|| format!("invalid url: {url}"))?;
        let host = parsed
            .host()
            .ok_or_else(|| anyhow!("missing host in {url}"))?;
        let port = parsed.port_u16().unwrap_or(match parsed.scheme_str() {
            Some("https") => 443,
            _ => 80,
        });
        let addr = format!("{host}:{port}");
        let authority = format!("{host}:{port}");
        Self::new(tcp_factory(addr), authority, token)
    }

    /// Current session_id, if `attach` has been called. Consumers
    /// building `?session=<id>` for the WS upgrades need this.
    pub fn session_id(&self) -> Option<String> {
        self.session_id.lock().unwrap().clone()
    }

    /// `GET /ping` — unauthenticated identity probe. Returns the parsed
    /// [`motif_proto::ping::PingInfo`] so callers can confirm the target is
    /// a motif-server before minting a session. Goes through the same
    /// stream factory as every other call, so it works over plain TCP,
    /// SSH tunnel, or tsnet alike.
    pub async fn ping(&self) -> anyhow::Result<motif_proto::ping::PingInfo> {
        let stream = (self.factory)().await?;
        let io = hyper_util::rt::TokioIo::new(stream);
        let (mut sender, conn) = hyper::client::conn::http1::handshake(io)
            .await
            .context("http1 handshake")?;
        let conn_task = tokio::spawn(async move {
            if let Err(e) = conn.await {
                tracing::debug!(error = %e, "http1 conn task exited");
            }
        });

        let req = Request::builder()
            .method(Method::GET)
            .uri("/ping")
            .header("host", &self.authority)
            .body(Full::new(Bytes::new()))
            .map_err(|e| anyhow!("build ping request: {e}"))?;

        let resp = sender.send_request(req).await.context("send /ping")?;
        let status = resp.status();
        let body_bytes = collect_body(resp.into_body()).await?;
        drop(sender);
        let _ = conn_task.await;

        if !status.is_success() {
            return Err(decode_error_response(status, &body_bytes));
        }
        serde_json::from_slice(&body_bytes).map_err(|e| anyhow!("decode /ping response: {e}"))
    }

    /// Generic RPC call. Serializes `params` to JSON, POSTs to
    /// `/rpc/<method>`, decodes the result.
    pub async fn call<P, R>(&self, method: &str, params: &P) -> anyhow::Result<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let body_bytes = serde_json::to_vec(params)?;
        let resp_bytes = self.raw_call(method, body_bytes).await?;
        serde_json::from_slice::<R>(&resp_bytes)
            .map_err(|e| anyhow!("decode response from `{method}`: {e}"))
    }

    /// `session.attach` + snap the new session_id off the response
    /// header. Future-proof: the server may also echo session_id in
    /// the body once we add a versioned proto, but for now we trust
    /// the header.
    pub async fn attach<P, R>(&self, params: &P) -> anyhow::Result<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let body_bytes = serde_json::to_vec(params)?;
        let (resp_bytes, sid_header) = self
            .raw_call_with_session_header("session.attach", body_bytes)
            .await?;
        if let Some(sid) = sid_header {
            *self.session_id.lock().unwrap() = Some(sid);
        } else {
            // Server is required to set the header on attach. Surface
            // the bug rather than silently leave session_id empty —
            // the next /events upgrade would fail with a confusing
            // 400/409 otherwise.
            return Err(anyhow!("server didn't return X-Motif-Session on attach"));
        }
        serde_json::from_slice::<R>(&resp_bytes).map_err(|e| anyhow!("decode attach response: {e}"))
    }

    /// `session.detach` — runs the RPC and clears the local session_id
    /// regardless of outcome. Idempotent: calling on an already-empty
    /// state just sends a no-op request.
    pub async fn detach(&self) -> anyhow::Result<()> {
        let _: serde_json::Value = self
            .call("session.detach", &serde_json::Value::Null)
            .await?;
        *self.session_id.lock().unwrap() = None;
        Ok(())
    }

    async fn raw_call(&self, method: &str, body: Vec<u8>) -> anyhow::Result<Vec<u8>> {
        let (bytes, _sid) = self.raw_call_with_session_header(method, body).await?;
        Ok(bytes)
    }

    async fn raw_call_with_session_header(
        &self,
        method: &str,
        body: Vec<u8>,
    ) -> anyhow::Result<(Vec<u8>, Option<String>)> {
        let stream = (self.factory)().await?;
        let io = hyper_util::rt::TokioIo::new(stream);
        let (mut sender, conn) = hyper::client::conn::http1::handshake(io)
            .await
            .context("http1 handshake")?;
        // Driver task — hyper requires this to be polled concurrently
        // with `sender.send_request`. It exits cleanly when we drop
        // the sender (request done).
        let conn_task = tokio::spawn(async move {
            if let Err(e) = conn.await {
                tracing::debug!(error = %e, "http1 conn task exited");
            }
        });

        let uri: Uri = format!("/rpc/{method}")
            .parse()
            .map_err(|e| anyhow!("bad method uri: {e}"))?;
        let mut req = Request::builder()
            .method(Method::POST)
            .uri(uri)
            .header("host", &self.authority)
            .header("authorization", self.auth.clone())
            .header("content-type", "application/json")
            .header("content-length", body.len().to_string())
            .body(Full::new(Bytes::from(body)))
            .map_err(|e| anyhow!("build request: {e}"))?;
        if let Some(sid) = self.session_id.lock().unwrap().clone() {
            if let Ok(v) = HeaderValue::from_str(&sid) {
                req.headers_mut().insert(SESSION_HEADER, v);
            }
        }

        let resp = sender.send_request(req).await.context("send_request")?;
        let status = resp.status();
        let session_header = resp
            .headers()
            .get(SESSION_HEADER)
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());
        let body_bytes = collect_body(resp.into_body()).await?;
        // Tear down the connection task before returning; with the
        // sender dropped, conn_task exits on its own, but await-ing it
        // makes the lifecycle deterministic.
        drop(sender);
        let _ = conn_task.await;

        if !status.is_success() {
            // Body should carry a JSON RpcError envelope for any 4xx
            // produced by `http_rpc::err_response`. Parse and surface
            // the structured error if we can; otherwise fall back to
            // status text.
            return Err(decode_error_response(status, &body_bytes));
        }
        Ok((body_bytes.to_vec(), session_header))
    }
}

async fn collect_body(body: Incoming) -> anyhow::Result<Bytes> {
    body.collect()
        .await
        .map(|b| b.to_bytes())
        .map_err(|e| anyhow!("read response body: {e}"))
}

fn decode_error_response(status: StatusCode, body: &[u8]) -> anyhow::Error {
    if let Ok(err) = serde_json::from_slice::<RpcError>(body) {
        return anyhow!("rpc error {}: {}", err.code, err.message);
    }
    let text = std::str::from_utf8(body).unwrap_or("<binary>");
    anyhow!("HTTP {}: {}", status.as_u16(), text)
}
