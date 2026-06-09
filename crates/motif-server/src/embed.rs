use axum::extract::Path as AxumPath;
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE};
use axum::http::{StatusCode, Uri};
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

pub async fn serve_spa_fallback(uri: Uri) -> Response {
    let key = uri.path().trim_start_matches('/');
    if !key.is_empty() {
        if let Some(response) = serve_existing(key) {
            return response;
        }
        if looks_like_static_asset(key) {
            return (StatusCode::NOT_FOUND, "not found").into_response();
        }
    }
    serve("index.html")
}

fn serve(path: &str) -> Response {
    let key = path.trim_start_matches('/');
    if let Some(response) = serve_existing(key) {
        return response;
    }
    (StatusCode::NOT_FOUND, "not found").into_response()
}

fn serve_existing(key: &str) -> Option<Response> {
    Assets::get(key).map(|asset| {
        (
            [(CONTENT_TYPE, mime_for(key)), (CACHE_CONTROL, "no-store")],
            asset.data.to_vec(),
        )
            .into_response()
    })
}

fn looks_like_static_asset(key: &str) -> bool {
    key.rsplit('/').next().unwrap_or("").contains('.')
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
        "map" => "application/json",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}
