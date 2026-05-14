//! Helpers for recognising AggLayer-bridged assets arriving in a user
//! Miden wallet.
//!
//! When `gateway-fm/miden-agglayer` processes an L1 deposit and creates
//! a CLAIM note on Miden, the bridge ultimately delivers a P2ID note
//! to the destination Miden wallet carrying a known AggLayer faucet's
//! asset. The SDK polls the wallet's incoming notes and uses this
//! helper to decide which ones came from the bridge.

use std::collections::HashSet;

/// One incoming bridged asset, as observed in a user wallet.
#[derive(Debug, Clone, Copy)]
pub struct IncomingBridgedAsset {
    pub faucet_id: u64,
    pub amount: u64,
}

/// Recognises AggLayer-faucet asset arrivals.
pub struct ClaimRecognition {
    known_agglayer_faucets: HashSet<u64>,
}

impl ClaimRecognition {
    pub fn new(faucet_ids: impl IntoIterator<Item = u64>) -> Self {
        Self {
            known_agglayer_faucets: faucet_ids.into_iter().collect(),
        }
    }

    pub fn is_bridged_faucet(&self, faucet_id: u64) -> bool {
        self.known_agglayer_faucets.contains(&faucet_id)
    }

    pub fn add_faucet(&mut self, faucet_id: u64) {
        self.known_agglayer_faucets.insert(faucet_id);
    }
}
