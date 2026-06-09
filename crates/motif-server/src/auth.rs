//! Bearer-token auth check during the WebSocket upgrade handshake.

use axum::http::HeaderMap;

/// Generate a fresh bearer token: 32 bytes from the OS RNG, base64url
/// (no padding) → 43 url-safe chars. Used by embedding hosts (the menu-bar
/// app) that mint a token for the user instead of reading one off disk.
pub fn generate_token() -> String {
    use base64::Engine;
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).expect("OS RNG unavailable");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

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
        if matches!(self, Self::Disabled) {
            return true;
        }
        let Some(value) = headers.get("authorization").and_then(|v| v.to_str().ok()) else {
            return false;
        };
        let Some(provided) = value.strip_prefix("Bearer ") else {
            return false;
        };
        self.verify_token(provided)
    }

    /// Browser WebSocket constructors cannot set Authorization headers.
    /// Same-origin web clients pass the same server token as `?token=...`.
    pub fn verify_header_or_query(&self, headers: &HeaderMap, query_token: Option<&str>) -> bool {
        self.verify_header(headers) || query_token.is_some_and(|token| self.verify_token(token))
    }

    fn verify_token(&self, provided: &str) -> bool {
        let expected = match self {
            Self::Disabled => return true,
            Self::Required(t) => t,
        };
        constant_time_eq(provided.as_bytes(), expected.as_bytes())
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
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
    fn generate_token_is_unique_and_urlsafe() {
        let a = generate_token();
        let b = generate_token();
        assert_ne!(a, b);
        assert_eq!(a.len(), 43); // 32 bytes base64url-nopad
        assert!(a
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
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
