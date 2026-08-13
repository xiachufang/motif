//! Authenticated WebSocket proxy for this server's one Codex app-server.

use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::ws::{
    CloseFrame as AxumCloseFrame, Message as AxumMessage, WebSocket, WebSocketUpgrade,
};
use axum::extract::{ConnectInfo, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};
use motif_net::PeerAddr;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::protocol::{
    frame::coding::CloseCode as TungsteniteCloseCode, CloseFrame as TungsteniteCloseFrame,
};
use tokio_tungstenite::tungstenite::Message as TungsteniteMessage;

use crate::codex_observer::{CodexObserver, PreparedTurn};
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
    let codex_for_start = Arc::clone(&codex);
    let runtime = match tokio::task::spawn_blocking(move || codex_for_start.start()).await {
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
    let observer = codex.observer();
    tracing::info!(peer = %peer, %client_id, "codex ws proxy connected");
    ws.on_upgrade(move |socket| async move {
        proxy(socket, upstream, runtime, observer, client_id).await;
    })
}

async fn proxy(
    client: WebSocket,
    upstream: tokio_tungstenite::WebSocketStream<TcpStream>,
    runtime: Arc<crate::codex_app_server::CodexAppServer>,
    observer: Arc<CodexObserver>,
    client_id: String,
) {
    let (mut client_tx, mut client_rx) = client.split();
    let (mut upstream_tx, mut upstream_rx) = upstream.split();
    let mut exited = runtime.subscribe_exit();
    let mut pending_turn_starts = HashMap::<String, PreparedTurn>::new();

    if *exited.borrow() {
        let _ = client_tx.send(close(1011, "codex app-server exited")).await;
        return;
    }

    loop {
        tokio::select! {
            inbound = client_rx.next() => match inbound {
                Some(Ok(message)) => {
                    let closing = matches!(message, AxumMessage::Close(_));
                    let mut prepared_key = None;
                    let turn_start = match &message {
                        AxumMessage::Text(text) => parse_turn_start(text.as_str()),
                        _ => None,
                    };
                    if let Some(start) = turn_start {
                        match observer
                            .prepare_turn(Arc::clone(&runtime), &start.thread_id)
                            .await
                        {
                            Ok(prepared) => {
                                if pending_turn_starts.contains_key(&start.request_key) {
                                    observer.cancel_turn(prepared);
                                    let reply = request_error(
                                        start.request_id,
                                        -32600,
                                        "duplicate in-flight turn/start request id",
                                    );
                                    if client_tx.send(reply).await.is_err() {
                                        break;
                                    }
                                    continue;
                                }
                                prepared_key = Some(start.request_key.clone());
                                pending_turn_starts.insert(start.request_key, prepared);
                            }
                            Err(error) => {
                                tracing::warn!(
                                    %client_id,
                                    thread_id = %start.thread_id,
                                    %error,
                                    "turn/start blocked because observer is unavailable"
                                );
                                let reply = request_error(
                                    start.request_id,
                                    -32090,
                                    &format!("notification observer unavailable: {error}"),
                                );
                                if client_tx.send(reply).await.is_err() {
                                    break;
                                }
                                continue;
                            }
                        }
                    }
                    if upstream_tx.send(to_upstream(message)).await.is_err() {
                        if let Some(key) = prepared_key {
                            if let Some(prepared) = pending_turn_starts.remove(&key) {
                                observer.cancel_turn(prepared);
                            }
                        }
                        break;
                    }
                    if closing {
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
                    let rpc_response = match &message {
                        TungsteniteMessage::Text(text) => parse_rpc_response(text.as_str()),
                        _ => None,
                    };
                    if let Some(response) = rpc_response {
                        if let Some(prepared) = pending_turn_starts.remove(&response.request_key) {
                            if response.succeeded {
                                observer.confirm_turn(prepared);
                            } else {
                                observer.cancel_turn(prepared);
                            }
                        }
                    }
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

#[derive(Debug, PartialEq)]
struct TurnStartRequest {
    request_id: Value,
    request_key: String,
    thread_id: String,
}

#[derive(Debug, PartialEq, Eq)]
struct RpcResponse {
    request_key: String,
    succeeded: bool,
}

fn parse_turn_start(text: &str) -> Option<TurnStartRequest> {
    let value = serde_json::from_str::<Value>(text).ok()?;
    (value.get("method").and_then(Value::as_str) == Some("turn/start")).then_some(())?;
    let request_id = value.get("id")?.clone();
    let request_key = request_key(&request_id)?;
    let thread_id = value
        .pointer("/params/threadId")?
        .as_str()?
        .trim()
        .to_string();
    (!thread_id.is_empty()).then_some(TurnStartRequest {
        request_id,
        request_key,
        thread_id,
    })
}

fn parse_rpc_response(text: &str) -> Option<RpcResponse> {
    let value = serde_json::from_str::<Value>(text).ok()?;
    let request_key = request_key(value.get("id")?)?;
    if value.get("error").is_some() {
        return Some(RpcResponse {
            request_key,
            succeeded: false,
        });
    }
    value.get("result").is_some().then_some(RpcResponse {
        request_key,
        succeeded: true,
    })
}

fn request_key(id: &Value) -> Option<String> {
    match id {
        Value::String(_) | Value::Number(_) => serde_json::to_string(id).ok(),
        _ => None,
    }
}

fn request_error(id: Value, code: i64, message: &str) -> AxumMessage {
    AxumMessage::Text(
        json!({
            "id": id,
            "error": {"code": code, "message": message},
        })
        .to_string()
        .into(),
    )
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

    #[test]
    fn recognizes_only_valid_turn_start_requests() {
        assert_eq!(
            parse_turn_start(
                r#"{"method":"turn/start","id":"start-1","params":{"threadId":"thr-1"}}"#
            ),
            Some(TurnStartRequest {
                request_id: json!("start-1"),
                request_key: "\"start-1\"".to_string(),
                thread_id: "thr-1".to_string(),
            })
        );
        assert!(parse_turn_start(
            r#"{"method":"thread/resume","id":1,"params":{"threadId":"thr-1"}}"#
        )
        .is_none());
        assert!(parse_turn_start(r#"{"method":"turn/start","id":1,"params":{}}"#).is_none());
    }

    #[test]
    fn correlates_string_and_numeric_rpc_responses() {
        assert_eq!(
            parse_rpc_response(r#"{"id":"start-1","result":{"turn":{}}}"#),
            Some(RpcResponse {
                request_key: "\"start-1\"".to_string(),
                succeeded: true,
            })
        );
        assert_eq!(
            parse_rpc_response(r#"{"id":42,"error":{"code":-1,"message":"no"}}"#),
            Some(RpcResponse {
                request_key: "42".to_string(),
                succeeded: false,
            })
        );
        assert!(parse_rpc_response(
            r#"{"method":"item/tool/requestUserInput","id":42,"params":{}}"#
        )
        .is_none());
    }

    #[test]
    fn observer_error_preserves_the_original_request_id() {
        let AxumMessage::Text(text) = request_error(json!("start-2"), -32090, "unavailable") else {
            panic!("expected a text response");
        };
        let value: Value = serde_json::from_str(text.as_str()).unwrap();
        assert_eq!(value["id"], "start-2");
        assert_eq!(value["error"]["code"], -32090);
    }
}
