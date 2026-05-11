//! Browser ↔ motifd bridging. The browser speaks the same JSON-RPC as a
//! native client, except its first frame is `auth.login` (browsers can't set
//! the `Authorization` header on a WS upgrade). The bridge intercepts that
//! single frame: it validates against the bridge's `--browser-token-file`,
//! synthesizes a successful response, then opens an upstream WS to motifd
//! (with the proper Bearer header) and forwards every subsequent frame in
//! both directions verbatim.

use axum::body::Body;
use axum::extract::ws::{Message as AxMessage, WebSocket};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use futures_util::{SinkExt, StreamExt};
use motif_proto::envelope::{Frame, Response as RpcResponse};
use motif_proto::error::{ErrorCode, RpcError};
use serde::Deserialize;
use serde_json::Value;
use tokio_tungstenite::{
    connect_async, tungstenite::client::IntoClientRequest,
    tungstenite::http::HeaderValue, tungstenite::Message as TgMessage,
};

use crate::config::WebConfig;

#[derive(Deserialize)]
struct LoginParams { token: String }

pub async fn run_browser_session(mut socket: WebSocket, cfg: WebConfig) {
    // ── 1. Wait for auth.login ─────────────────────────────────────────────
    let first = match socket.recv().await {
        Some(Ok(AxMessage::Text(t))) => t.to_string(),
        Some(Ok(AxMessage::Close(_))) | None => return,
        _ => {
            let _ = socket.send(close_with_code(4401, "first message must be auth.login")).await;
            return;
        }
    };

    let frame: Frame = match serde_json::from_str(&first) {
        Ok(f)  => f,
        Err(_) => {
            let _ = socket.send(close_with_code(4400, "invalid JSON")).await;
            return;
        }
    };
    let req = match frame {
        Frame::Request(r) if r.method == "auth.login" => r,
        _ => {
            let _ = socket.send(close_with_code(4401, "first message must be auth.login")).await;
            return;
        }
    };
    let p: LoginParams = match serde_json::from_value(req.params) {
        Ok(p)  => p,
        Err(e) => {
            let _ = socket.send(text_response(&RpcResponse::err(
                req.id.clone(), RpcError::invalid_params(format!("bad auth.login params: {e}"))))).await;
            return;
        }
    };
    if p.token != cfg.browser_token {
        let _ = socket.send(text_response(&RpcResponse::err(
            req.id.clone(), RpcError::new(ErrorCode::AuthRequired, "invalid token")))).await;
        let _ = socket.send(close_with_code(4401, "invalid token")).await;
        return;
    }

    // ── 2. Open upstream WS to motifd with our service token ──────────────
    let upstream_url = adjust_motifd_url(&cfg.motifd_url, "/ws");
    let mut upstream_req = match upstream_url.as_str().into_client_request() {
        Ok(r)  => r,
        Err(_) => { let _ = socket.send(close_with_code(4500, "bad motifd-url")).await; return; }
    };
    upstream_req.headers_mut().insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {}", cfg.motifd_token))
            .unwrap_or(HeaderValue::from_static("Bearer")),
    );
    let upstream = match connect_async(upstream_req).await {
        Ok((ws, _)) => ws,
        Err(e) => {
            tracing::warn!("upstream connect failed: {e}");
            let _ = socket.send(close_with_code(4503, "upstream unavailable")).await;
            return;
        }
    };

    // Reply to the auth.login.
    let ok = RpcResponse::ok(req.id.clone(), serde_json::json!({
        "client_id": "via-motif-web",
        "server_version": env!("CARGO_PKG_VERSION"),
    }));
    let _ = socket.send(text_response(&ok)).await;

    // ── 3. Forward frames bidirectionally ─────────────────────────────────
    let (mut ax_tx, mut ax_rx) = socket.split();
    let (mut up_tx, mut up_rx) = upstream.split();

    let down = async {
        while let Some(msg) = up_rx.next().await {
            match msg {
                Ok(TgMessage::Text(t))   => { if ax_tx.send(AxMessage::Text(t.to_string().into())).await.is_err() { break; } }
                Ok(TgMessage::Binary(b)) => { if ax_tx.send(AxMessage::Binary(b)).await.is_err() { break; } }
                Ok(TgMessage::Close(_))  => { let _ = ax_tx.send(AxMessage::Close(None)).await; break; }
                Ok(_)                     => continue,
                Err(_)                    => break,
            }
        }
    };
    let up = async {
        while let Some(msg) = ax_rx.next().await {
            match msg {
                Ok(AxMessage::Text(t))   => { if up_tx.send(TgMessage::Text(t.to_string().into())).await.is_err() { break; } }
                Ok(AxMessage::Binary(b)) => { if up_tx.send(TgMessage::Binary(b)).await.is_err() { break; } }
                Ok(AxMessage::Close(_))  => { let _ = up_tx.send(TgMessage::Close(None)).await; break; }
                Ok(_)                     => continue,
                Err(_)                    => break,
            }
        }
    };
    tokio::select! { _ = down => {}, _ = up => {} }
}

// ── Blob HTTP wrappers ────────────────────────────────────────────────────

pub async fn blob_get(cfg: WebConfig, tid: String) -> Response {
    let url = adjust_motifd_url(&cfg.motifd_url, &format!("/blob/{tid}"));
    let mut req = match url.as_str().into_client_request() {
        Ok(r)  => r,
        Err(_) => return (StatusCode::BAD_REQUEST, "bad motifd-url").into_response(),
    };
    req.headers_mut().insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {}", cfg.motifd_token)).unwrap(),
    );
    let upstream = match connect_async(req).await {
        Ok((ws, _)) => ws,
        Err(e) => {
            tracing::warn!("upstream blob connect: {e}");
            return (StatusCode::BAD_GATEWAY, format!("upstream connect: {e}")).into_response();
        }
    };
    let (_w, mut r) = upstream.split();

    let (tx, rx) = tokio::sync::mpsc::channel::<Result<bytes::Bytes, std::io::Error>>(8);
    tokio::spawn(async move {
        while let Some(item) = r.next().await {
            match item {
                Ok(TgMessage::Binary(b)) => { if tx.send(Ok(bytes::Bytes::from(b))).await.is_err() { break; } }
                Ok(TgMessage::Close(_))  => break,
                Ok(_)                     => continue,
                Err(_)                    => break,
            }
        }
    });

    let stream = tokio_stream::wrappers::ReceiverStream::new(rx);
    Response::builder()
        .status(StatusCode::OK)
        .header("Cache-Control", "no-store")
        .body(Body::from_stream(stream))
        .unwrap()
}

pub async fn blob_put(cfg: WebConfig, tid: String, body: Body) -> Response {
    let url = adjust_motifd_url(&cfg.motifd_url, &format!("/blob/{tid}"));
    let mut req = match url.as_str().into_client_request() {
        Ok(r)  => r,
        Err(_) => return (StatusCode::BAD_REQUEST, "bad motifd-url").into_response(),
    };
    req.headers_mut().insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {}", cfg.motifd_token)).unwrap(),
    );
    let upstream = match connect_async(req).await {
        Ok((ws, _)) => ws,
        Err(_)      => return (StatusCode::BAD_GATEWAY, "upstream connect failed").into_response(),
    };
    let (mut up_tx, _up_rx) = upstream.split();
    let mut data = body.into_data_stream();
    while let Some(chunk) = data.next().await {
        match chunk {
            Ok(bytes) => {
                if up_tx.send(TgMessage::Binary(bytes.to_vec().into())).await.is_err() { break; }
            }
            Err(_) => break,
        }
    }
    let _ = up_tx.send(TgMessage::Close(None)).await;
    StatusCode::OK.into_response()
}

// ── helpers ───────────────────────────────────────────────────────────────

fn text_response(r: &RpcResponse) -> AxMessage {
    AxMessage::Text(serde_json::to_string(r).unwrap_or_default().into())
}

fn close_with_code(code: u16, reason: &str) -> AxMessage {
    AxMessage::Close(Some(axum::extract::ws::CloseFrame {
        code, reason: reason.to_string().into(),
    }))
}

fn adjust_motifd_url(base: &str, suffix: &str) -> String {
    // base examples: "ws://host:7777/", "wss://host:7777/foo"
    // suffix examples: "/ws", "/blob/01HX..."
    if let Ok(mut u) = url::Url::parse(base) {
        u.set_path(suffix);
        return u.to_string();
    }
    format!("{}{}", base.trim_end_matches('/'), suffix)
}

#[allow(unused_imports)]
use serde_json as _sj;
#[allow(unused_imports)]
use Value as _v;
