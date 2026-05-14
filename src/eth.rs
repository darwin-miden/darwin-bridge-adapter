//! Minimal Ethereum-side types used by the bridge.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EthAddress([u8; 20]);

impl EthAddress {
    pub const fn from_bytes(bytes: [u8; 20]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> [u8; 20] {
        self.0
    }

    /// Parses a `0x`-prefixed hex string into an `EthAddress`. Returns
    /// `None` on any malformed input (wrong length, non-hex chars,
    /// missing prefix, etc.).
    pub fn parse_hex(s: &str) -> Option<Self> {
        let hex = s.strip_prefix("0x").unwrap_or(s);
        if hex.len() != 40 {
            return None;
        }
        let mut out = [0u8; 20];
        for (i, chunk) in hex.as_bytes().chunks(2).enumerate() {
            let hi = ascii_hex_to_nibble(chunk[0])?;
            let lo = ascii_hex_to_nibble(chunk[1])?;
            out[i] = (hi << 4) | lo;
        }
        Some(Self(out))
    }

    /// Renders this address as a `0x`-prefixed lowercase hex string.
    pub fn to_hex(self) -> String {
        let mut s = String::with_capacity(42);
        s.push_str("0x");
        for b in self.0 {
            s.push(nibble_to_hex(b >> 4));
            s.push(nibble_to_hex(b & 0xf));
        }
        s
    }
}

fn ascii_hex_to_nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

fn nibble_to_hex(n: u8) -> char {
    match n {
        0..=9 => (b'0' + n) as char,
        10..=15 => (b'a' + n - 10) as char,
        _ => unreachable!(),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum EthNetwork {
    /// Polygon AggLayer's canonical network id for Ethereum L1.
    Ethereum,
    /// AggLayer's network id for Polygon zkEVM rollup.
    PolygonZkEvm,
    /// Custom override — use only for local testing.
    Custom(u32),
}

impl EthNetwork {
    pub fn id(self) -> u32 {
        match self {
            EthNetwork::Ethereum => 0,
            EthNetwork::PolygonZkEvm => 1,
            EthNetwork::Custom(n) => n,
        }
    }
}

impl std::fmt::Debug for EthNetwork {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EthNetwork::Ethereum => write!(f, "EthNetwork::Ethereum(0)"),
            EthNetwork::PolygonZkEvm => write!(f, "EthNetwork::PolygonZkEvm(1)"),
            EthNetwork::Custom(n) => write!(f, "EthNetwork::Custom({n})"),
        }
    }
}
