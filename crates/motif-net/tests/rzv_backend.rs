//! WSS rendezvous accept backend end to end against the real relay router.

mod common;

use axum::serve::Listener as _;
use futures_util::{SinkExt, StreamExt};
use motif_net::{ListenConfig, RzvListenConfig};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::Message;

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
