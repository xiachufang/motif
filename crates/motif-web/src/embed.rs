use axum::http::header::CONTENT_TYPE;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "static/"]
pub struct Assets;

pub fn serve(path: &str) -> Response {
    let path = path.trim_start_matches('/');
    let key  = if path.is_empty() { "index.html" } else { path };
    if let Some(asset) = Assets::get(key) {
        let mime = mime_for(key);
        return ([(CONTENT_TYPE, mime)], asset.data.to_vec()).into_response();
    }
    // SPA fallback: serve index.html for unknown paths so client-side routing works.
    if let Some(idx) = Assets::get("index.html") {
        return ([(CONTENT_TYPE, "text/html; charset=utf-8")], idx.data.to_vec()).into_response();
    }
    (StatusCode::NOT_FOUND, "not found").into_response()
}

fn mime_for(key: &str) -> &'static str {
    match key.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js"   => "application/javascript",
        "css"  => "text/css",
        "json" => "application/json",
        "svg"  => "image/svg+xml",
        "png"  => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "ico"  => "image/x-icon",
        "wasm" => "application/wasm",
        _      => "application/octet-stream",
    }
}
