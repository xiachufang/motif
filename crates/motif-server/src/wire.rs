//! Codec helpers for the `/ws` channel.
//!
//! The control plane has two negotiated codecs:
//! - `Codec::Json`   — text frames, `serde_json` (the original).
//! - `Codec::Binary` — binary frames, MessagePack via `rmp_serde`.
//!
//! Inbound binary requests carry their `params` as an `rmpv::Value` so the
//! decoder can losslessly hold msgpack `bin` types (which serde_json::Value
//! cannot represent). We then convert to a JSON Value at the dispatch
//! boundary — base64-encoding any byte fields — so the rest of the
//! dispatch path can stay JSON-shaped and the typed param decoders (which
//! use the `bytes_base64_or_native` adapter) round-trip the bytes back
//! through base64. The only field on the wire that takes this hit is
//! `PtyWriteParams.data`; everything else is JSON-compatible.
//!
//! Outbound responses and events are serialized straight from their typed
//! Rust shape via `rmp_serde::to_vec_named`, so byte fields stay native
//! msgpack `bin` (the high-volume path is `pty.output`, which dominates
//! the wire and gets the full binary win).

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};

/// Wire-format negotiated at WS upgrade time via `?bin=1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Codec {
    #[default]
    Json,
    Binary,
}

/// Convert an `rmpv::Value` (which can represent msgpack `bin`) into a
/// `serde_json::Value` (which cannot). Byte strings become base64 JSON
/// strings — the typed-params layer base64-decodes them back via the
/// `motif_proto::wire::bytes_base64_or_native` adapter, so handlers see
/// the original raw bytes.
pub fn rmpv_to_json(v: rmpv::Value) -> serde_json::Value {
    use rmpv::Value as R;
    use serde_json::Value as J;
    use serde_json::Number;
    match v {
        R::Nil               => J::Null,
        R::Boolean(b)        => J::Bool(b),
        R::Integer(n)        => {
            if let Some(u) = n.as_u64() {
                J::Number(Number::from(u))
            } else if let Some(i) = n.as_i64() {
                J::Number(Number::from(i))
            } else if let Some(f) = n.as_f64() {
                Number::from_f64(f).map(J::Number).unwrap_or(J::Null)
            } else {
                J::Null
            }
        }
        R::F32(f)            => Number::from_f64(f as f64).map(J::Number).unwrap_or(J::Null),
        R::F64(f)            => Number::from_f64(f).map(J::Number).unwrap_or(J::Null),
        R::String(s)         => J::String(s.into_str().unwrap_or_default()),
        R::Binary(bytes)     => J::String(BASE64.encode(&bytes)),
        R::Array(xs)         => J::Array(xs.into_iter().map(rmpv_to_json).collect()),
        R::Map(pairs)        => {
            let mut obj = serde_json::Map::with_capacity(pairs.len());
            for (k, v) in pairs {
                let key = match k {
                    R::String(s) => s.into_str().unwrap_or_default(),
                    other        => other.to_string(),
                };
                obj.insert(key, rmpv_to_json(v));
            }
            J::Object(obj)
        }
        R::Ext(_, _)         => J::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_becomes_base64_string() {
        let raw = vec![0u8, 1, 2, 3, 0xff];
        let v = rmpv::Value::Binary(raw.clone());
        let j = rmpv_to_json(v);
        assert_eq!(j, serde_json::Value::String(BASE64.encode(&raw)));
    }

    #[test]
    fn nested_map_round_trip() {
        let v = rmpv::Value::Map(vec![
            (rmpv::Value::from("pty_id"), rmpv::Value::from("p1")),
            (rmpv::Value::from("data_b64"), rmpv::Value::Binary(vec![1, 2, 3])),
        ]);
        let j = rmpv_to_json(v);
        let obj = j.as_object().expect("object");
        assert_eq!(obj["pty_id"], serde_json::Value::from("p1"));
        // data_b64 base64-encoded under the same key — typed PtyWriteParams
        // deserializer will decode back to Vec<u8> via the wire adapter.
        assert_eq!(obj["data_b64"], serde_json::Value::String(BASE64.encode(&[1u8, 2, 3])));
    }
}
