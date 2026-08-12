//! Authenticated WebSocket proxy for this server's one Codex app-server.

use axum::extract::ws::{
    CloseFrame as AxumCloseFrame, Message as AxumMessage, WebSocket, WebSocketUpgrade,
};
use axum::extract::{ConnectInfo, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use motif_net::PeerAddr;
use serde::Deserialize;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::protocol::{
    frame::coding::CloseCode as TungsteniteCloseCode, CloseFrame as TungsteniteCloseFrame,
};
use tokio_tungstenite::tungstenite::Message as TungsteniteMessage;

use crate::ws::AppState;

#[derive(Debug, Default, Deserialize)]
pub struct CodexQuery {
    pub token: Option<String>,
}

pub async fn codex_upgrade(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<PeerAddr>,
    headers: HeaderMap,
    Query(query): Query<CodexQuery>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    if !state
        .auth
        .verify_header_or_query(&headers, query.token.as_deref())
    {
        tracing::warn!(peer = %peer, "codex ws auth rejected");
        return (StatusCode::UNAUTHORIZED, "missing or invalid Bearer token").into_response();
    }

    let codex = state.codex.clone();
    let runtime = match tokio::task::spawn_blocking(move || codex.start()).await {
        Ok(Ok(runtime)) => runtime,
        Ok(Err(error)) => {
            tracing::warn!(peer = %peer, %error, "codex app-server start failed");
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "codex app-server is unavailable",
            )
                .into_response();
        }
        Err(error) => {
            tracing::warn!(peer = %peer, %error, "codex app-server start task failed");
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "codex app-server is unavailable",
            )
                .into_response();
        }
    };

    // Build a fresh inner WebSocket for every Motif client. `client_async`
    // creates only the WebSocket handshake headers, so Motif Authorization and
    // browser Origin are never forwarded to the loopback service.
    let address = runtime.address();
    let tcp = match TcpStream::connect(address).await {
        Ok(tcp) => tcp,
        Err(error) => {
            tracing::warn!(%address, %error, "codex app-server dial failed");
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "codex app-server is unavailable",
            )
                .into_response();
        }
    };
    let upstream_url = format!("ws://{address}");
    let (upstream, _) = match tokio_tungstenite::client_async(upstream_url, tcp).await {
        Ok(upstream) => upstream,
        Err(error) => {
            tracing::warn!(%address, %error, "codex app-server websocket handshake failed");
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                "codex app-server websocket unavailable",
            )
                .into_response();
        }
    };

    let client_id = ulid::Ulid::new().to_string();
    tracing::info!(peer = %peer, %client_id, "codex ws proxy connected");
    ws.on_upgrade(move |socket| async move {
        proxy(socket, upstream, runtime, client_id).await;
    })
}

async fn proxy(
    client: WebSocket,
    upstream: tokio_tungstenite::WebSocketStream<TcpStream>,
    runtime: std::sync::Arc<crate::codex_app_server::CodexAppServer>,
    client_id: String,
) {
    let (mut client_tx, mut client_rx) = client.split();
    let (mut upstream_tx, mut upstream_rx) = upstream.split();
    let mut exited = runtime.subscribe_exit();

    if *exited.borrow() {
        let _ = client_tx.send(close(1011, "codex app-server exited")).await;
        return;
    }

    loop {
        tokio::select! {
            inbound = client_rx.next() => match inbound {
                Some(Ok(message)) => {
                    let closing = matches!(message, AxumMessage::Close(_));
                    if upstream_tx.send(to_upstream(message)).await.is_err() || closing {
                        break;
                    }
                }
                Some(Err(error)) => {
                    tracing::debug!(%client_id, %error, "codex client websocket read failed");
                    break;
                }
                None => break,
            },
            inbound = upstream_rx.next() => match inbound {
                Some(Ok(message)) => {
                    let closing = matches!(message, TungsteniteMessage::Close(_));
                    if let Some(message) = to_client(message) {
                        if client_tx.send(message).await.is_err() || closing {
                            break;
                        }
                    }
                }
                Some(Err(error)) => {
                    tracing::debug!(%client_id, %error, "codex upstream websocket read failed");
                    let _ = client_tx.send(close(1011, "codex app-server connection failed")).await;
                    break;
                }
                None => {
                    let _ = client_tx.send(close(1011, "codex app-server disconnected")).await;
                    break;
                },
            },
            changed = exited.changed() => {
                if changed.is_err() || *exited.borrow() {
                    let _ = client_tx.send(close(1011, "codex app-server exited")).await;
                    break;
                }
            }
        }
    }
    tracing::info!(%client_id, "codex ws proxy disconnected");
}

fn to_upstream(message: AxumMessage) -> TungsteniteMessage {
    match message {
        AxumMessage::Text(value) => TungsteniteMessage::Text(value.as_str().into()),
        AxumMessage::Binary(value) => TungsteniteMessage::Binary(value),
        AxumMessage::Ping(value) => TungsteniteMessage::Ping(value),
        AxumMessage::Pong(value) => TungsteniteMessage::Pong(value),
        AxumMessage::Close(frame) => {
            TungsteniteMessage::Close(frame.map(|frame| TungsteniteCloseFrame {
                code: TungsteniteCloseCode::from(frame.code),
                reason: frame.reason.as_str().into(),
            }))
        }
    }
}

fn to_client(message: TungsteniteMessage) -> Option<AxumMessage> {
    Some(match message {
        TungsteniteMessage::Text(value) => AxumMessage::Text(value.as_str().into()),
        TungsteniteMessage::Binary(value) => AxumMessage::Binary(value),
        TungsteniteMessage::Ping(value) => AxumMessage::Ping(value),
        TungsteniteMessage::Pong(value) => AxumMessage::Pong(value),
        TungsteniteMessage::Close(frame) => AxumMessage::Close(frame.map(|frame| AxumCloseFrame {
            code: frame.code.into(),
            reason: frame.reason.as_str().into(),
        })),
        TungsteniteMessage::Frame(_) => return None,
    })
}

fn close(code: u16, reason: &'static str) -> AxumMessage {
    AxumMessage::Close(Some(AxumCloseFrame {
        code,
        reason: reason.into(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_data_and_control_frames_in_both_directions() {
        assert!(matches!(
            to_upstream(AxumMessage::Text("hello".into())),
            TungsteniteMessage::Text(value) if value == "hello"
        ));
        assert!(matches!(
            to_upstream(AxumMessage::Binary(vec![1, 2, 3].into())),
            TungsteniteMessage::Binary(value) if value.as_ref() == [1, 2, 3]
        ));
        assert!(matches!(
            to_client(TungsteniteMessage::Ping(vec![4, 5].into())),
            Some(AxumMessage::Ping(value)) if value.as_ref() == [4, 5]
        ));
        assert!(matches!(
            to_client(TungsteniteMessage::Pong(vec![6].into())),
            Some(AxumMessage::Pong(value)) if value.as_ref() == [6]
        ));
    }

    #[test]
    fn preserves_close_code_and_reason() {
        let upstream = to_upstream(AxumMessage::Close(Some(AxumCloseFrame {
            code: 4001,
            reason: "client reason".into(),
        })));
        assert!(matches!(
            upstream,
            TungsteniteMessage::Close(Some(frame))
                if u16::from(frame.code) == 4001 && frame.reason == "client reason"
        ));

        let client = to_client(TungsteniteMessage::Close(Some(TungsteniteCloseFrame {
            code: TungsteniteCloseCode::from(4002),
            reason: "server reason".into(),
        })));
        assert!(matches!(
            client,
            Some(AxumMessage::Close(Some(frame)))
                if frame.code == 4002 && frame.reason == "server reason"
        ));
    }
}
