//! Darwin AggLayer bridge integration.
//!
//! Two facets:
//!
//!   1. **B2AGG note construction** — Rust builders that produce the
//!      `B2AGG` note targeted at the AggLayer bridge account from
//!      `miden-agglayer` v0.14-alpha. Used by `darwin-sdk` to bridge a
//!      Darwin basket token (DCC / DAG / DCO) out to Ethereum.
//!   2. **CLAIM note recognition** — utilities to detect when a P2ID
//!      note carrying an AggLayer-bridged asset has arrived in a user's
//!      Miden wallet, so the SDK can surface it as "ready to deposit
//!      into a basket".
//!
//! Plus a `contracts/` directory with Solidity stubs for the L1
//! wrapper ERC20s (`wDCC`, `wDAG`, `wDCO`) that ship in M3.

pub mod b2agg;
pub mod claim;
pub mod eth;

pub use b2agg::{B2AggBuildError, B2AggBuilder};
pub use claim::{ClaimRecognition, IncomingBridgedAsset};
pub use eth::{EthAddress, EthNetwork};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eth_address_round_trip() {
        let bytes = [0x12u8; 20];
        let addr = EthAddress::from_bytes(bytes);
        assert_eq!(addr.as_bytes(), bytes);
    }

    #[test]
    fn eth_address_hex_round_trip() {
        let hex = "0x2a3dd3eb832af982ec71669e178424b10dca2ede";
        let addr = EthAddress::parse_hex(hex).expect("parses");
        assert_eq!(addr.to_hex(), hex);
    }

    #[test]
    fn eth_address_parse_rejects_malformed() {
        assert!(EthAddress::parse_hex("0xshort").is_none());
        assert!(EthAddress::parse_hex("not_hex").is_none());
        assert!(EthAddress::parse_hex("0x2a3dd3eb832af982ec71669e178424b10dca2ed").is_none());
        assert!(EthAddress::parse_hex("0x2a3dd3eb832af982ec71669e178424b10dca2edez").is_none());
    }

    #[test]
    fn b2agg_builder_requires_asset_and_destination() {
        let err = B2AggBuilder::new().build().unwrap_err();
        assert!(matches!(err, B2AggBuildError::MissingAsset));
    }

    #[test]
    fn b2agg_builder_happy_path() {
        let b = B2AggBuilder::new()
            .asset_faucet_id(0xDEADBEEF)
            .amount(1_000_000_000)
            .destination_network(EthNetwork::Ethereum)
            .destination_address(EthAddress::from_bytes([0x42; 20]))
            .build()
            .expect("builds");
        assert_eq!(b.amount, 1_000_000_000);
        assert_eq!(b.destination_address.as_bytes()[0], 0x42);
    }
}
