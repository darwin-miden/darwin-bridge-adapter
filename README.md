# darwin-bridge-adapter

AggLayer bridge integration for Darwin Protocol: `B2AGG` note builder, `CLAIM` note recognition, and Solidity stubs for the L1 wrapper ERC20s (`wDCC`, `wDAG`, `wDCO`).

See [`darwin-docs/m1-architecture-spec.md`](https://github.com/darwin-miden/darwin-docs/blob/main/docs/m1-architecture-spec.md) §10 for the full specification.

## What this crate does

1. **B2AGG construction.** `B2AggBuilder` produces an immutable description of a bridge-out note (basket faucet id, amount, destination chain, destination address). When `miden-agglayer` is added to the workspace, this builder will return a full `miden_agglayer::B2AggNote` instead.
2. **CLAIM recognition.** `ClaimRecognition` tracks the set of canonical AggLayer faucet ids and lets the SDK detect when an inbound P2ID note in a user wallet originated from a bridge claim.
3. **L1 wrapper stubs.** `contracts/WrappedBasketToken.sol` is a minimal ERC20 owned by the AggLayer Unified Bridge contract. It mints on claim, burns on `bridgeAsset` round-trip.

## Layout

```
darwin-bridge-adapter/
├── Cargo.toml
├── src/
│   ├── lib.rs
│   ├── b2agg.rs           # B2AggBuilder
│   ├── claim.rs           # ClaimRecognition
│   └── eth.rs             # EthAddress, EthNetwork
├── contracts/
│   └── WrappedBasketToken.sol
```

## Status

Scaffold. The Rust API compiles and three unit tests cover the happy path and failure modes of the B2AGG builder. The Solidity contract has not yet been compiled with Foundry — that lands when `darwin-infra` ships the docker stack.

## License

MIT.
