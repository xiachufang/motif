//! Bearer-token auth check during the WebSocket upgrade handshake.

use axum::http::HeaderMap;

#[derive(Debug, Clone)]
pub struct TokenStore {
    expected: String,
}

impl TokenStore {
    pub fn new(token: impl Into<String>) -> Self {
        Self { expected: token.into() }
    }

    /// Constant-time check of the `Authorization: Bearer <token>` header.
    pub fn verify_header(&self, headers: &HeaderMap) -> bool {
        let Some(value) = headers.get("authorization").and_then(|v| v.to_str().ok()) else {
            return false;
        };
        let Some(provided) = value.strip_prefix("Bearer ") else {
            return false;
        };
        constant_time_eq(provided.as_bytes(), self.expected.as_bytes())
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
        assert!(!TokenStore::new("abc").verify_header(&h));
    }

    #[test]
    fn rejects_wrong_scheme() {
        let mut h = HeaderMap::new();
        h.insert("authorization", "Basic abc".parse().unwrap());
        assert!(!TokenStore::new("abc").verify_header(&h));
    }

    #[test]
    fn accepts_correct_bearer() {
        let mut h = HeaderMap::new();
        h.insert("authorization", "Bearer s3cret".parse().unwrap());
        assert!(TokenStore::new("s3cret").verify_header(&h));
    }

    #[test]
    fn rejects_wrong_token() {
        let mut h = HeaderMap::new();
        h.insert("authorization", "Bearer wrong".parse().unwrap());
        assert!(!TokenStore::new("right").verify_header(&h));
    }
}
