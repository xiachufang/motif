//! Browser CORS coverage for motifd's HTTP surface.

mod common;

use std::net::SocketAddr;

use anyhow::{Context, Result};
use bytes::Bytes;
use common::{auth_headers, TestServer};
use http::header::{
    ACCESS_CONTROL_ALLOW_HEADERS, ACCESS_CONTROL_ALLOW_METHODS, ACCESS_CONTROL_ALLOW_ORIGIN,
    ACCESS_CONTROL_EXPOSE_HEADERS, ACCESS_CONTROL_REQUEST_HEADERS, ACCESS_CONTROL_REQUEST_METHOD,
    ORIGIN,
};
use http_body_util::{BodyExt, Full};
use hyper::client::conn::http1;
use hyper_util::rt::TokioIo;
use motif_server::http_rpc::SESSION_HEADER;
use tokio::net::TcpStream;

#[tokio::test]
async fn cors_preflight_allows_rpc_from_any_origin() {
    let server = TestServer::start().await;
    let headers = vec![
        (ORIGIN.as_str(), "https://example.test".to_string()),
        (ACCESS_CONTROL_REQUEST_METHOD.as_str(), "POST".to_string()),
        (
            ACCESS_CONTROL_REQUEST_HEADERS.as_str(),
            format!("authorization, content-type, {SESSION_HEADER}"),
        ),
    ];

    let (status, resp_headers, body) = http_request(
        server.addr,
        "OPTIONS",
        "/rpc/session.list",
        &headers,
        vec![],
    )
    .await
    .unwrap();

    assert!(
        status.is_success(),
        "preflight failed with {status}: {}",
        String::from_utf8_lossy(&body)
    );
    assert_eq!(
        resp_headers
            .get(ACCESS_CONTROL_ALLOW_ORIGIN)
            .and_then(|v| v.to_str().ok()),
        Some("*")
    );
    assert_header_contains(&resp_headers, ACCESS_CONTROL_ALLOW_METHODS, "POST");
    assert_header_allows(&resp_headers, ACCESS_CONTROL_ALLOW_HEADERS, "authorization");
    assert_header_allows(&resp_headers, ACCESS_CONTROL_ALLOW_HEADERS, SESSION_HEADER);
}

#[tokio::test]
async fn cors_headers_are_added_to_actual_responses() {
    let server = TestServer::start().await;
    let mut headers = auth_headers(&server.token);
    headers.push((ORIGIN.as_str(), "https://example.test".to_string()));

    let (status, resp_headers, body) = http_request(server.addr, "GET", "/ping", &headers, vec![])
        .await
        .unwrap();

    assert!(
        status.is_success(),
        "ping failed with {status}: {}",
        String::from_utf8_lossy(&body)
    );
    assert_eq!(
        resp_headers
            .get(ACCESS_CONTROL_ALLOW_ORIGIN)
            .and_then(|v| v.to_str().ok()),
        Some("*")
    );
    assert_header_contains(&resp_headers, ACCESS_CONTROL_EXPOSE_HEADERS, SESSION_HEADER);
}

fn assert_header_contains(headers: &http::HeaderMap, name: http::HeaderName, needle: &str) {
    let value = headers
        .get(name.clone())
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        value
            .split(',')
            .map(str::trim)
            .any(|part| part.eq_ignore_ascii_case(needle)),
        "expected {name} to contain {needle:?}, got {value:?}"
    );
}

fn assert_header_allows(headers: &http::HeaderMap, name: http::HeaderName, needle: &str) {
    let value = headers
        .get(name.clone())
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(
        value == "*"
            || value
                .split(',')
                .map(str::trim)
                .any(|part| part.eq_ignore_ascii_case(needle)),
        "expected {name} to allow {needle:?}, got {value:?}"
    );
}

async fn http_request(
    addr: SocketAddr,
    method: &str,
    path: &str,
    headers: &[(&str, String)],
    body: Vec<u8>,
) -> Result<(http::StatusCode, http::HeaderMap, Vec<u8>)> {
    let stream = TcpStream::connect(addr)
        .await
        .with_context(|| format!("connect {addr}"))?;
    let io = TokioIo::new(stream);
    let (mut sender, conn) = http1::handshake(io).await.context("http1 handshake")?;
    let driver = tokio::spawn(async move {
        let _ = conn.await;
    });

    let mut req = http::Request::builder()
        .method(method)
        .uri(path)
        .header(http::header::HOST, addr.to_string());
    for (k, v) in headers {
        req = req.header(*k, v.as_str());
    }
    let req = req
        .body(Full::<Bytes>::from(body))
        .context("build request")?;

    let resp = sender.send_request(req).await.context("send_request")?;
    let (parts, body) = resp.into_parts();
    let bytes = body
        .collect()
        .await
        .context("collect body")?
        .to_bytes()
        .to_vec();
    driver.abort();
    Ok((parts.status, parts.headers, bytes))
}
