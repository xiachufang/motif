//! JSON-RPC 2.0 envelope (Request / Response / Notification).
//!
//! We model frames as a single `Frame` enum that round-trips through JSON
//! with serde's `untagged` derivation — a frame is one of:
//!   - Request   (has `id` + `method` + `params`)
//!   - Notification (no `id`, `method` + `params`)
//!   - Response  (has `id` + either `result` or `error`)
//!
//! Both client→server and server→client frames use this same shape; routing
//! is handled by the higher layer based on `id` vs no-`id` and method.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::RpcError;

pub const JSONRPC_V2: &str = "2.0";

/// JSON-RPC request id. We only use numeric ids in motif (server assigns
/// monotonic counters); strings are accepted for inbound parsing in case some
/// future client needs them, but never produced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Id {
    Num(u64),
    Str(String),
}

impl From<u64> for Id { fn from(n: u64) -> Self { Self::Num(n) } }

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub jsonrpc: String,
    pub id:      Id,
    pub method:  String,
    #[serde(default = "default_params")]
    pub params:  Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Notification {
    pub jsonrpc: String,
    pub method:  String,
    #[serde(default = "default_params")]
    pub params:  Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub jsonrpc: String,
    pub id:      Id,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub result:  Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub error:   Option<RpcError>,
}

fn default_params() -> Value { Value::Null }

/// Top-level frame for inbound parsing. Outbound construction uses `Request`,
/// `Notification`, or `Response` directly via convenience constructors below.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Frame {
    Request(Request),
    /// Note: order matters for `untagged` — Response must come before Notification
    /// because Response carries `id` and Notification does not, but Request also
    /// carries `id`. serde_json picks the first variant whose required fields are
    /// present, so Response (id + result/error) and Request (id + method) are
    /// distinguished by serde's strict matching.
    Response(Response),
    Notification(Notification),
}

impl Request {
    pub fn new<P: Serialize>(id: u64, method: impl Into<String>, params: P) -> Self {
        Self {
            jsonrpc: JSONRPC_V2.into(),
            id:      Id::Num(id),
            method:  method.into(),
            params:  serde_json::to_value(params).unwrap_or(Value::Null),
        }
    }
}

impl Notification {
    pub fn new<P: Serialize>(method: impl Into<String>, params: P) -> Self {
        Self {
            jsonrpc: JSONRPC_V2.into(),
            method:  method.into(),
            params:  serde_json::to_value(params).unwrap_or(Value::Null),
        }
    }
}

impl Response {
    pub fn ok<R: Serialize>(id: Id, result: R) -> Self {
        Self {
            jsonrpc: JSONRPC_V2.into(),
            id,
            result: Some(serde_json::to_value(result).unwrap_or(Value::Null)),
            error:  None,
        }
    }

    pub fn err(id: Id, error: RpcError) -> Self {
        Self {
            jsonrpc: JSONRPC_V2.into(),
            id,
            result: None,
            error:  Some(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn request_round_trip() {
        let r = Request::new(7, "session.list", json!({}));
        let s = serde_json::to_string(&r).unwrap();
        assert!(s.contains("\"jsonrpc\":\"2.0\""));
        assert!(s.contains("\"id\":7"));
        assert!(s.contains("\"method\":\"session.list\""));
        let back: Request = serde_json::from_str(&s).unwrap();
        assert_eq!(back.id, Id::Num(7));
    }

    #[test]
    fn frame_dispatches_request() {
        let raw = r#"{"jsonrpc":"2.0","id":1,"method":"session.list","params":{}}"#;
        let f: Frame = serde_json::from_str(raw).unwrap();
        assert!(matches!(f, Frame::Request(_)));
    }

    #[test]
    fn frame_dispatches_notification() {
        let raw = r#"{"jsonrpc":"2.0","method":"client.joined","params":{"client_id":"ABC","since":1234,"seq":1}}"#;
        let f: Frame = serde_json::from_str(raw).unwrap();
        assert!(matches!(f, Frame::Notification(_)));
    }

    #[test]
    fn frame_dispatches_response_ok() {
        let raw = r#"{"jsonrpc":"2.0","id":1,"result":{"sessions":[]}}"#;
        let f: Frame = serde_json::from_str(raw).unwrap();
        assert!(matches!(f, Frame::Response(_)));
    }

    #[test]
    fn frame_dispatches_response_err() {
        let raw = r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"AuthRequired"}}"#;
        let f: Frame = serde_json::from_str(raw).unwrap();
        match f {
            Frame::Response(r) => {
                assert!(r.error.is_some());
                assert_eq!(r.error.unwrap().code, -32001);
            }
            _ => panic!("expected Response"),
        }
    }
}
