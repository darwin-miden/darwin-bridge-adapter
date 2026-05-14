//! Rust builder for `B2AGG` notes.
//!
//! Once `miden-agglayer` is added to the workspace, this builder will
//! return a full `miden_agglayer::B2AggNote`. For now it produces a
//! `B2AggBuild` value that captures all the inputs the bridge needs.

use crate::eth::{EthAddress, EthNetwork};

#[derive(Debug, Default)]
pub struct B2AggBuilder {
    asset_faucet_id: Option<u64>,
    amount: Option<u64>,
    destination_network: Option<EthNetwork>,
    destination_address: Option<EthAddress>,
}

#[derive(Debug, Clone, Copy)]
pub struct B2AggBuild {
    pub asset_faucet_id: u64,
    pub amount: u64,
    pub destination_network: EthNetwork,
    pub destination_address: EthAddress,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum B2AggBuildError {
    #[error("asset (faucet_id + amount) must be set before building")]
    MissingAsset,
    #[error("destination_network and destination_address must be set before building")]
    MissingDestination,
    #[error("amount must be > 0")]
    ZeroAmount,
}

impl B2AggBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn asset_faucet_id(mut self, faucet_id: u64) -> Self {
        self.asset_faucet_id = Some(faucet_id);
        self
    }

    pub fn amount(mut self, amount: u64) -> Self {
        self.amount = Some(amount);
        self
    }

    pub fn destination_network(mut self, network: EthNetwork) -> Self {
        self.destination_network = Some(network);
        self
    }

    pub fn destination_address(mut self, address: EthAddress) -> Self {
        self.destination_address = Some(address);
        self
    }

    pub fn build(self) -> Result<B2AggBuild, B2AggBuildError> {
        let asset_faucet_id = self.asset_faucet_id.ok_or(B2AggBuildError::MissingAsset)?;
        let amount = self.amount.ok_or(B2AggBuildError::MissingAsset)?;
        if amount == 0 {
            return Err(B2AggBuildError::ZeroAmount);
        }
        let destination_network = self
            .destination_network
            .ok_or(B2AggBuildError::MissingDestination)?;
        let destination_address = self
            .destination_address
            .ok_or(B2AggBuildError::MissingDestination)?;
        Ok(B2AggBuild {
            asset_faucet_id,
            amount,
            destination_network,
            destination_address,
        })
    }
}
