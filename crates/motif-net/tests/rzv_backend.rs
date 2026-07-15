//! WSS rendezvous accept backend end to end against the real relay router.

mod common;

use axum::serve::Listener as _;
use futures_util::{SinkExt, StreamExt};
use motif_net::{ListenConfig, RzvListenConfig};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::Message;

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
    assert!(listener
        .bound_addrs()
        .iter()
        .any(|a| a.starts_with("rzv://")));

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
