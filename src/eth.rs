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
