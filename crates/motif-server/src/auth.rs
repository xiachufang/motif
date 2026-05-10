//! Bearer-token auth check during the WebSocket upgrade handshake.

use axum::http::HeaderMap;

#[derive(Debug, Clone)]
pub enum TokenStore {
    /// Verify `Authorization: Bearer <token>` against the configured value.
    Required(String),
    /// No token configured — accept every upgrade. The operator opted in via
    /// the absence of `--token-file`; lib.rs gates this against the listen
    /// surface so we can't accidentally expose a public TCP port.
    Disabled,
}

impl TokenStore {
    pub fn required(token: impl Into<String>) -> Self {
        Self::Required(token.into())
    }

    pub fn disabled() -> Self {
        Self::Disabled
    }

    /// Constant-time check of the `Authorization: Bearer <token>` header.
    /// Always returns true in `Disabled` mode.
    pub fn verify_header(&self, headers: &HeaderMap) -> bool {
        let expected = match self {
            Self::Disabled => return true,
            Self::Required(t) => t,
        };
        let Some(value) = headers.get("authorization").and_then(|v| v.to_str().ok()) else {
            return false;
        };
        let Some(provided) = value.strip_prefix("Bearer ") else {
            return false;
        };
        constant_time_eq(provided.as_bytes(), expected.as_bytes())
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() { return false; }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_missing_header() {
        let h = HeaderMap::new();
        assert!(!TokenStore::required("abc").verify_header(&h));
    }

    #[test]
    fn rejects_wrong_scheme() {
        let mut h = HeaderMap::new();
        h.insert("authorization", "Basic abc".parse().unwrap());
        assert!(!TokenStore::required("abc").verify_header(&h));
    }

    #[test]
    fn accepts_correct_bearer() {
        let mut h = HeaderMap::new();
        h.insert("authorization", "Bearer s3cret".parse().unwrap());
        assert!(TokenStore::required("s3cret").verify_header(&h));
    }

    #[test]
    fn rejects_wrong_token() {
        let mut h = HeaderMap::new();
        h.insert("authorization", "Bearer wrong".parse().unwrap());
        assert!(!TokenStore::required("right").verify_header(&h));
    }

    #[test]
    fn disabled_accepts_anything() {
        let store = TokenStore::disabled();
        assert!(store.verify_header(&HeaderMap::new()));
        let mut h = HeaderMap::new();
        h.insert("authorization", "Bearer whatever".parse().unwrap());
        assert!(store.verify_header(&h));
    }
}
