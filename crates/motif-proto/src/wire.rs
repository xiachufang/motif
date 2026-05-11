//! Wire-format glue shared by the JSON and MessagePack codecs.
//!
//! `bytes_base64_or_native` is a serde adapter for byte-array fields that
//! shows up as base64 strings in human-readable serializers (JSON) and as
//! native byte strings in binary serializers (MessagePack). This is the
//! single piece of "two-format" code in the codebase — every other type
//! stays untouched and goes through plain serde derive.

pub mod bytes_base64_or_native {
    use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
    use serde::de::Error as _;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], ser: S) -> Result<S::Ok, S::Error> {
        if ser.is_human_readable() {
            BASE64.encode(bytes).serialize(ser)
        } else {
            serde_bytes::Bytes::new(bytes).serialize(ser)
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(de: D) -> Result<Vec<u8>, D::Error> {
        if de.is_human_readable() {
            let s = String::deserialize(de)?;
            BASE64.decode(s.as_bytes()).map_err(D::Error::custom)
        } else {
            Ok(serde_bytes::ByteBuf::deserialize(de)?.into_vec())
        }
    }
}

#[cfg(test)]
mod tests {
    use serde::{Deserialize, Serialize};

    #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
    struct Sample {
        #[serde(with = "super::bytes_base64_or_native")]
        data: Vec<u8>,
    }

    #[test]
    fn json_uses_base64() {
        let s = Sample { data: vec![0, 1, 2, 3, 0xff] };
        let json = serde_json::to_string(&s).unwrap();
        // Wire is base64 string, not an array.
        assert!(json.contains("\"data\":\"AAECA/8=\""));
        let back: Sample = serde_json::from_str(&json).unwrap();
        assert_eq!(back, s);
    }

    #[test]
    fn msgpack_uses_native_bytes() {
        let s = Sample { data: vec![0, 1, 2, 3, 0xff] };
        let buf = rmp_serde::to_vec_named(&s).unwrap();
        // msgpack bin8 marker (0xc4) for a 5-byte string sits right after
        // the fixmap header — proves we didn't emit base64.
        assert!(buf.windows(2).any(|w| w[0] == 0xc4 && w[1] == 5));
        let back: Sample = rmp_serde::from_slice(&buf).unwrap();
        assert_eq!(back, s);
    }
}
