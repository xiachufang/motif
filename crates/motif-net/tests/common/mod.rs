use std::net::SocketAddr;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use motif_rendezvous::{build_hello, Authenticator, Hub, HubConfig, CTRL_PAIRED};
use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

pub struct TestRelay {
    pub addr: SocketAddr,
    pub jwt: String,
}

#[derive(Serialize)]
struct Claims<'a> {
    iss: &'a str,
    aud: &'a str,
    sub: &'a str,
    exp: usize,
}

pub async fn start_relay() -> TestRelay {
    let tmp = tempfile::tempdir().unwrap();
    let key = tmp.path().join("jwt.key");
    std::fs::write(&key, b"test-rendezvous-secret").unwrap();
    let config = tmp.path().join("auth.json");
    std::fs::write(
        &config,
        serde_json::to_vec(&serde_json::json!({
            "jwt": {
                "algorithm": "HS256",
                "issuer": "motif-test",
                "audience": "motif-rendezvous-test",
                "verification_key": key
            },
            "users": {
                "test-owner": {
                    "client_to_server_bytes_per_sec": 10000000,
                    "server_to_client_bytes_per_sec": 10000000,
                    "burst_bytes": 1000000
                }
            }
        }))
        .unwrap(),
    )
    .unwrap();
    let auth = Authenticator::from_file(&config).unwrap();
    let jwt = encode(
        &Header::new(Algorithm::HS256),
        &Claims {
            iss: "motif-test",
            aud: "motif-rendezvous-test",
            sub: "test-owner",
            exp: 4_102_444_800,
        },
        &EncodingKey::from_secret(b"test-rendezvous-secret"),
    )
    .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let hub = Hub::new(
        HubConfig {
            park_ttl: Duration::from_secs(30),
            keepalive: Duration::from_secs(1),
        },
        auth,
    );
    hub.spawn_reaper();
    tokio::spawn(async move { axum::serve(listener, hub.router()).await.unwrap() });
    TestRelay { addr, jwt }
}

pub async fn connect_client(addr: SocketAddr, token: &[u8; 32]) -> WebSocketStream<TcpStream> {
    let tcp = TcpStream::connect(addr).await.unwrap();
    let request = format!("ws://{addr}/v2/connect")
        .into_client_request()
        .unwrap();
    let (mut ws, _) = tokio_tungstenite::client_async(request, tcp).await.unwrap();
    ws.send(Message::Binary(build_hello(token).into()))
        .await
        .unwrap();
    loop {
        match ws.next().await.unwrap().unwrap() {
            Message::Binary(bytes) if bytes.as_ref() == [CTRL_PAIRED] => return ws,
            Message::Ping(bytes) => ws.send(Message::Pong(bytes)).await.unwrap(),
            Message::Pong(_) => {}
            other => panic!("unexpected pre-pair WebSocket message {other:?}"),
        }
    }
}

#[allow(dead_code)]
pub fn websocket_byte_stream(mut ws: WebSocketStream<TcpStream>) -> tokio::io::DuplexStream {
    let (local, tunnel) = tokio::io::duplex(256 * 1024);
    tokio::spawn(async move {
        let (mut rd, mut wr) = tokio::io::split(tunnel);
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            tokio::select! {
                message = ws.next() => match message {
                    Some(Ok(Message::Binary(bytes))) => {
                        if wr.write_all(&bytes).await.is_err() { return; }
                    }
                    Some(Ok(Message::Ping(bytes))) => {
                        if ws.send(Message::Pong(bytes)).await.is_err() { return; }
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    _ => return,
                },
                read = rd.read(&mut buf) => match read {
                    Ok(0) | Err(_) => return,
                    Ok(n) => {
                        if ws.send(Message::Binary(buf[..n].to_vec().into())).await.is_err() {
                            return;
                        }
                    }
                }
            }
        }
    });
    local
}
