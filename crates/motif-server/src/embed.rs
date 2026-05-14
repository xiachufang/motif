use axum::extract::Path as AxumPath;
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "static/"]
pub struct Assets;

pub async fn serve_index() -> Response {
    serve("index.html")
}

pub async fn serve_assets(AxumPath(path): AxumPath<String>) -> Response {
    serve(&format!("assets/{path}"))
}

pub async fn serve_spa_fallback() -> Response {
    serve("index.html")
}

fn serve(path: &str) -> Response {
    let key = path.trim_start_matches('/');
    if let Some(asset) = Assets::get(key) {
        return (
            [(CONTENT_TYPE, mime_for(key)), (CACHE_CONTROL, "no-store")],
            asset.data.to_vec(),
        )
            .into_response();
    }
    (StatusCode::NOT_FOUND, "not found").into_response()
}

fn mime_for(key: &str) -> &'static str {
    match key.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" => "application/javascript",
        "css" => "text/css",
        "json" => "application/json",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "ico" => "image/x-icon",
        "wasm" => "application/wasm",
        _ => "application/octet-stream",
    }
}
