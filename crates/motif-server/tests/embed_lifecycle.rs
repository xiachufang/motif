//! The embeddable `start()` / `RunningServer` control path that the
//! menu-bar app drives: bind on an ephemeral loopback port, confirm it
//! actually serves `/ping`, then shut down within the grace window.

use std::time::Duration;

use motif_server::{start, ServerConfig};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn loopback_cfg() -> ServerConfig {
    ServerConfig {
        listen: Some(([127, 0, 0, 1], 0).into()), // port 0 → OS-assigned
        listen_tls: None,
        tailscale: None,
        rendezvous: None,
        rzv_direct: None,
        token: None,
        push_relay_url: None,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn embed_start_ping_shutdown() {
    let server = start(loopback_cfg()).await.expect("start");

    let addrs = server.bound_addrs().to_vec();
    assert!(!addrs.is_empty(), "expected a bound address");
    assert_eq!(server.session_count(), 0);

    let addr = addrs
        .iter()
        .find_map(|a| a.strip_prefix("tcp://"))
        .expect("a tcp:// bound address");

    let mut s = tokio::net::TcpStream::connect(addr).await.expect("connect");
    let req = format!("GET /ping HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n");
    s.write_all(req.as_bytes()).await.unwrap();
    let mut buf = Vec::new();
    s.read_to_end(&mut buf).await.unwrap();
    let text = String::from_utf8_lossy(&buf);
    assert!(
        text.contains("\"service\":\"motif-server\""),
        "ping body did not identify a motif-server: {text}"
    );

    tokio::time::timeout(Duration::from_secs(5), server.shutdown())
        .await
        .expect("shutdown exceeded grace window")
        .expect("shutdown returned an error");
}
