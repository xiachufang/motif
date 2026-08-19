//! WSS rendezvous accept backend end to end against the real relay router.

mod common;

use axum::serve::Listener as _;
use futures_util::{SinkExt, StreamExt};
use motif_net::{ListenConfig, RzvListenConfig};
use motif_rendezvous::{build_hello, CTRL_PAIRED};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

async fn park_unresponsive_accept(
    relay: &common::TestRelay,
    token: &[u8; 32],
) -> WebSocketStream<TcpStream> {
    let tcp = TcpStream::connect(relay.addr).await.unwrap();
    let mut request = format!("ws://{}/v2/accept", relay.addr)
        .into_client_request()
        .unwrap();
    request.headers_mut().insert(
        "Authorization",
        format!("Bearer {}", relay.jwt).parse().unwrap(),
    );
    let (mut socket, _) = tokio_tungstenite::client_async(request, tcp).await.unwrap();
    socket
        .send(Message::Binary(build_hello(token).into()))
        .await
        .unwrap();
    socket
}

async fn connect_without_waiting_for_pair(
    addr: std::net::SocketAddr,
    token: &[u8; 32],
) -> WebSocketStream<TcpStream> {
    let tcp = TcpStream::connect(addr).await.unwrap();
    let request = format!("ws://{addr}/v2/connect")
        .into_client_request()
        .unwrap();
    let (mut socket, _) = tokio_tungstenite::client_async(request, tcp).await.unwrap();
    socket
        .send(Message::Binary(build_hello(token).into()))
        .await
        .unwrap();
    socket
}

async fn wait_for_rzv_status(
    status: &mut tokio::sync::watch::Receiver<motif_net::RzvStatus>,
    predicate: impl Fn(&motif_net::RzvStatus) -> bool,
) -> motif_net::RzvStatus {
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let current = status.borrow().clone();
            if predicate(&current) {
                return current;
            }
            status.changed().await.expect("rzv status sender dropped");
        }
    })
    .await
    .expect("timed out waiting for rendezvous status")
}

#[tokio::test]
async fn rzv_backend_pairs_and_pipes() {
    let relay = common::start_relay().await;
    let token = [9u8; 32];
    let mut listener = motif_net::Listener::bind(&ListenConfig {
        tcp: None,
        tcp_tls: None,
        tailscale: None,
        rendezvous: Some(RzvListenConfig::new(
            format!("ws://{}", relay.addr),
            token,
            relay.jwt,
        )),
    })
    .await
    .unwrap();
    let mut status = listener.rendezvous_status().expect("rzv status");
    assert!(listener
        .bound_addrs()
        .iter()
        .any(|a| a.starts_with("rzv://")));

    let connected = wait_for_rzv_status(&mut status, |s| s.connected).await;
    assert_eq!(connected.error, None);

    let mut client = common::connect_client(relay.addr, &token).await;
    let (mut stream, _addr) = listener.accept().await;

    client
        .send(Message::Binary(Vec::from(&b"hi-motifd"[..]).into()))
        .await
        .unwrap();
    let mut a = [0u8; 9];
    stream.read_exact(&mut a).await.unwrap();
    assert_eq!(&a, b"hi-motifd");

    stream.write_all(b"hi-client").await.unwrap();
    stream.flush().await.unwrap();
    loop {
        match client.next().await.unwrap().unwrap() {
            Message::Binary(bytes) => {
                assert_eq!(bytes.as_ref(), b"hi-client");
                break;
            }
            Message::Ping(bytes) => client.send(Message::Pong(bytes)).await.unwrap(),
            Message::Pong(_) => {}
            other => panic!("unexpected relay message {other:?}"),
        }
    }
}

#[tokio::test]
async fn relay_skips_a_parked_accept_that_misses_keepalive_pongs() {
    let keepalive = std::time::Duration::from_millis(25);
    let relay = common::start_relay_with_keepalive(keepalive).await;
    let token = [10u8; 32];
    let _stale = park_unresponsive_accept(&relay, &token).await;

    // The relay sends one PING immediately and closes on the deadline after
    // three unanswered PINGs. Leave an extra period for scheduler jitter.
    tokio::time::sleep(keepalive * 4).await;

    let mut client = connect_without_waiting_for_pair(relay.addr, &token).await;
    let message = tokio::time::timeout(keepalive * 2, client.next())
        .await
        .expect("connect waiter received no keepalive")
        .expect("connect waiter closed")
        .expect("connect waiter failed");
    assert!(
        !matches!(message, Message::Binary(bytes) if bytes.as_ref() == [CTRL_PAIRED]),
        "client must not be paired with an unresponsive accept waiter"
    );
}

#[tokio::test]
async fn rzv_backend_reconnects_without_draining_a_stale_accept_pool() {
    let keepalive = std::time::Duration::from_millis(25);
    let relay = common::start_relay_with_keepalive(keepalive).await;
    let token = [11u8; 32];
    let mut stale = Vec::new();
    for _ in 0..4 {
        stale.push(park_unresponsive_accept(&relay, &token).await);
    }

    tokio::time::sleep(keepalive * 4).await;

    let mut config = RzvListenConfig::new(format!("ws://{}", relay.addr), token, relay.jwt.clone());
    config.pool = 4;
    let mut listener = motif_net::Listener::bind(&ListenConfig {
        tcp: None,
        tcp_tls: None,
        tailscale: None,
        rendezvous: Some(config),
    })
    .await
    .unwrap();
    let mut status = listener.rendezvous_status().expect("rzv status");
    wait_for_rzv_status(&mut status, |state| state.connected).await;

    let mut client = common::connect_client(relay.addr, &token).await;
    let (mut stream, _) =
        tokio::time::timeout(std::time::Duration::from_secs(1), listener.accept())
            .await
            .expect("client was paired with a stale accept instead of the live pool");
    client
        .send(Message::Binary(Vec::from(&b"reconnected"[..]).into()))
        .await
        .unwrap();
    let mut bytes = [0u8; 11];
    stream.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"reconnected");

    drop(stale);
}

#[tokio::test]
async fn rzv_backend_reports_rejected_owner_jwt() {
    let relay = common::start_relay().await;
    let mut config = RzvListenConfig::new(
        format!("ws://{}", relay.addr),
        [7u8; 32],
        "not-a-valid-owner-jwt",
    );
    config.pool = 1;
    let listener = motif_net::Listener::bind(&ListenConfig {
        tcp: None,
        tcp_tls: None,
        tailscale: None,
        rendezvous: Some(config),
    })
    .await
    .unwrap();
    let mut status = listener.rendezvous_status().expect("rzv status");

    let failed = wait_for_rzv_status(&mut status, |s| s.error.is_some()).await;
    let error = failed.error.expect("relay error");
    assert!(
        error.contains("401") || error.to_ascii_lowercase().contains("unauthorized"),
        "unexpected auth error: {error}"
    );
}

#[tokio::test]
async fn rzv_backend_uses_refreshed_owner_jwt_without_rebind() {
    let relay = common::start_relay().await;
    let mut config = RzvListenConfig::new(
        format!("ws://{}", relay.addr),
        [6u8; 32],
        "expired-owner-jwt",
    );
    config.pool = 1;
    let jwt = config.jwt_handle();
    let listener = motif_net::Listener::bind(&ListenConfig {
        tcp: None,
        tcp_tls: None,
        tailscale: None,
        rendezvous: Some(config),
    })
    .await
    .unwrap();
    let mut status = listener.rendezvous_status().expect("rzv status");

    wait_for_rzv_status(&mut status, |s| s.error.is_some()).await;
    jwt.set(relay.jwt);
    let connected = wait_for_rzv_status(&mut status, |s| s.connected).await;
    assert_eq!(connected.error, None);
}

#[tokio::test]
async fn rzv_backend_reports_unreachable_relay() {
    let probe = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = probe.local_addr().unwrap();
    drop(probe);

    let mut config = RzvListenConfig::new(format!("ws://{addr}"), [8u8; 32], "unused");
    config.pool = 1;
    let listener = motif_net::Listener::bind(&ListenConfig {
        tcp: None,
        tcp_tls: None,
        tailscale: None,
        rendezvous: Some(config),
    })
    .await
    .unwrap();
    let mut status = listener.rendezvous_status().expect("rzv status");

    let failed = wait_for_rzv_status(&mut status, |s| s.error.is_some()).await;
    assert!(!failed.connected);
    assert!(failed.error.expect("relay error").contains("refused"));
}
