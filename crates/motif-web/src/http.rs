use axum::extract::ws::WebSocketUpgrade;
use axum::extract::{Path as AxumPath, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get, put};
use axum::Router;

use crate::bridge;
use crate::config::WebConfig;
use crate::embed;

pub fn router(cfg: WebConfig) -> Router {
    Router::new()
        .route("/",           get(serve_index))
        .route("/assets/{*p}", get(serve_assets))
        .route("/ws",         get(ws_upgrade))
        .route("/blob/{tid}", any(blob_handler))
        .route("/blob_put/{tid}", put(blob_handler))   // optional alias
        .with_state(cfg)
}

async fn serve_index() -> Response { embed::serve("/") }
async fn serve_assets(AxumPath(p): AxumPath<String>) -> Response {
    embed::serve(&format!("assets/{}", p))
}

async fn ws_upgrade(
    State(cfg): State<WebConfig>,
    ws:          WebSocketUpgrade,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| bridge::run_browser_session(socket, cfg))
}

async fn blob_handler(
    State(cfg):       State<WebConfig>,
    AxumPath(tid):    AxumPath<String>,
    method:           axum::http::Method,
    headers:          axum::http::HeaderMap,
    body:             axum::body::Body,
) -> Response {
    if !auth_header_ok(&headers, &cfg.browser_token) {
        return (StatusCode::UNAUTHORIZED, "missing or invalid Bearer token").into_response();
    }
    match method.as_str() {
        "GET" => bridge::blob_get(cfg, tid).await,
        "PUT" => bridge::blob_put(cfg, tid, body).await,
        _ => (StatusCode::METHOD_NOT_ALLOWED, "use GET to download or PUT to upload").into_response(),
    }
}

fn auth_header_ok(h: &axum::http::HeaderMap, expected: &str) -> bool {
    let Some(v) = h.get("authorization").and_then(|v| v.to_str().ok()) else { return false };
    let Some(t) = v.strip_prefix("Bearer ") else { return false };
    t == expected
}
