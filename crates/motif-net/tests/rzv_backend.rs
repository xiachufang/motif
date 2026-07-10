//! The rzv accept backend, end to end against the real `motif-rendezvous`
//! relay: a parked `accept` pump pairs with a `connect` client and surfaces a
//! transparent stream through `Listener::accept`.

use axum::serve::Listener as _;
use motif_net::{ListenConfig, RzvListenConfig};
use motif_rendezvous::{
    Hub, HubConfig, CTRL_PAIRED, CTRL_PING, CTRL_PONG, MAGIC, ROLE_CONNECT, VERSION,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

#[tokio::test]
async fn rzv_backend_pairs_and_pipes() {
    // Real relay.
    let relay = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_addr = relay.local_addr().unwrap();
    tokio::spawn(Hub::new(HubConfig::default()).run(relay));

    // motifd side: park accept waiters at the relay.
    let token = [9u8; 32];
    let mut listener = motif_net::Listener::bind(&ListenConfig {
        tcp: None,
        tcp_tls: None,
        tailscale: None,
        rendezvous: Some(RzvListenConfig {
            url: relay_addr.to_string(),
            token,
            pool: 2,
            tls: None,
        }),
    })
    .await
    .unwrap();
    assert!(listener
        .bound_addrs()
        .iter()
        .any(|a| a.starts_with("rzv://")));

    // Client side: dial the relay and present a connect HELLO. The relay queues
    // either side until its partner shows, so ordering vs the pump is fine.
    let mut client = TcpStream::connect(relay_addr).await.unwrap();
    let mut hello = Vec::new();
    hello.extend_from_slice(&MAGIC);
    hello.push(VERSION);
    hello.push(ROLE_CONNECT);
    hello.extend_from_slice(&token);
    client.write_all(&hello).await.unwrap();
    client.flush().await.unwrap();

    loop {
        let mut control = [0u8; 1];
        client.read_exact(&mut control).await.unwrap();
        match control[0] {
            CTRL_PAIRED => break,
            CTRL_PING => client.write_all(&[CTRL_PONG]).await.unwrap(),
            other => panic!("unexpected pre-pair control byte {other:#04x}"),
        }
    }

    // motif-net surfaces the paired stream.
    let (mut stream, _addr) = listener.accept().await;

    // client -> motifd
    client.write_all(b"hi-motifd").await.unwrap();
    let mut a = [0u8; 9];
    stream.read_exact(&mut a).await.unwrap();
    assert_eq!(&a, b"hi-motifd");

    // motifd -> client
    stream.write_all(b"hi-client").await.unwrap();
    let mut b = [0u8; 9];
    client.read_exact(&mut b).await.unwrap();
    assert_eq!(&b, b"hi-client");
}
