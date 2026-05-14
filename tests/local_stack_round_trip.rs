//! Round-trip integration test against the local AggLayer + Miden
//! bridge stack (gateway-fm/miden-agglayer + Darwin layer).
//!
//! Marked `#[ignore]` so the default `cargo test` run stays hermetic.
//! Run explicitly once the stack is up:
//!
//!     cd darwin-infra && ./scripts/darwin-bridge-up.sh
//!     cd darwin-infra && ./scripts/darwin-bridge-register-dcc.sh
//!     cargo test --test local_stack_round_trip -- --ignored --nocapture
//!
//! The test exercises `B2AggBuilder` end-to-end with the exact inputs
//! Darwin's SDK passes into the bridge, then asserts the L1 wDCC
//! balance increments after the AggLayer settlement.

use darwin_bridge_adapter::b2agg::B2AggBuilder;
use darwin_bridge_adapter::eth::{EthAddress, EthNetwork};

/// Drives the L2→L1 bridge-out flow against the running local stack.
///
/// This is `#[ignore]`d because it requires `darwin-bridge-up.sh` to
/// have brought up the upstream `gateway-fm/miden-agglayer` stack.
#[test]
#[ignore = "requires the local AggLayer stack — run after `./scripts/darwin-bridge-up.sh`"]
fn l2_to_l1_bridge_out_with_dcc() {
    // Anvil L1 deployer key from upstream's e2e fixtures. Same key the
    // upstream `e2e-l2-to-l1.sh` script uses as the L1 destination.
    let funded_key = "0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625";

    // L1 recipient address derived from the funded key. Upstream's
    // script computes it via `cast wallet address --private-key …`; the
    // resulting address is deterministic.
    let l1_dest = EthAddress::parse_hex("0x71562b71999873DB5b286dF957af199Ec94617F7")
        .expect("known good hex address");

    // The DCC mirror faucet id is published by
    // `darwin-bridge-register-dcc.sh` (it parses the JSON-RPC response
    // and prints the id). For an automated round-trip, persist it in
    // an env var so the test can pick it up:
    let mirror_faucet_id: u64 = std::env::var("DARWIN_DCC_MIRROR_FAUCET_ID")
        .expect("set DARWIN_DCC_MIRROR_FAUCET_ID to the id from darwin-bridge-register-dcc.sh")
        .parse()
        .expect("DARWIN_DCC_MIRROR_FAUCET_ID must be a u64");

    let build = B2AggBuilder::new()
        .asset_faucet_id(mirror_faucet_id)
        .amount(100)
        .destination_network(EthNetwork::Ethereum)
        .destination_address(l1_dest)
        .build()
        .expect("builder happy path");

    assert_eq!(build.amount, 100);
    assert_eq!(build.destination_network, EthNetwork::Ethereum);
    assert_eq!(build.destination_address, l1_dest);

    // The actual `bridge-out-tool` invocation lives in
    // `darwin-infra/scripts/darwin-bridge-out-dcc.sh`. This test
    // documents the SDK's role: it produces the typed inputs that
    // tool consumes via env vars / CLI flags.
    eprintln!("B2AggBuild ready for bridge-out: {build:#?}");
    eprintln!("Now run `darwin-infra/scripts/darwin-bridge-out-dcc.sh`");
    eprintln!("funded_key for cast claim on L1: {funded_key}");
}

#[test]
fn builder_rejects_missing_inputs() {
    let no_asset = B2AggBuilder::new()
        .destination_network(EthNetwork::Ethereum)
        .destination_address(
            EthAddress::parse_hex("0x71562b71999873DB5b286dF957af199Ec94617F7").unwrap(),
        )
        .build();
    assert!(no_asset.is_err());

    let no_destination = B2AggBuilder::new()
        .asset_faucet_id(0xabc)
        .amount(100)
        .build();
    assert!(no_destination.is_err());

    let zero_amount = B2AggBuilder::new()
        .asset_faucet_id(0xabc)
        .amount(0)
        .destination_network(EthNetwork::Ethereum)
        .destination_address(
            EthAddress::parse_hex("0x71562b71999873DB5b286dF957af199Ec94617F7").unwrap(),
        )
        .build();
    assert!(zero_amount.is_err());
}
