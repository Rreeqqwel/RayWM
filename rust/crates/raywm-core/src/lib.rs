//! Framework-independent bootstrap configuration. Desktop policy comes later.

use std::{error::Error, fmt};

/// A socket basename inside the private XDG runtime directory.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SocketName(String);

impl SocketName {
    pub fn new(name: String) -> Result<Self, InvalidSocketName> {
        if name.is_empty()
            || name == "."
            || name == ".."
            || !name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
        {
            return Err(InvalidSocketName);
        }
        Ok(Self(name))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug)]
pub struct InvalidSocketName;

impl fmt::Display for InvalidSocketName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("socket name must be a basename containing only ASCII letters, digits, '.', '_' or '-' (except '.' and '..')")
    }
}

impl Error for InvalidSocketName {}

/// Stage 1 is always headless; there is no implicit session/DRM fallback.
#[derive(Debug, Default)]
pub struct HeadlessConfig {
    pub socket_name: Option<SocketName>,
}

#[cfg(test)]
mod tests {
    use super::SocketName;

    #[test]
    fn socket_names_cannot_escape_the_runtime_directory() {
        for invalid in [
            "",
            ".",
            "..",
            "/tmp/display",
            "../display",
            "a/b",
            "a\0b",
            "a b",
        ] {
            assert!(SocketName::new(invalid.into()).is_err(), "{invalid:?}");
        }
        assert!(SocketName::new("raywm-test_1.0".into()).is_ok());
    }
}
