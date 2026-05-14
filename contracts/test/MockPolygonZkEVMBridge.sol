// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {WrappedBasketToken} from "../WrappedBasketToken.sol";

/// @title MockPolygonZkEVMBridge
/// @notice Minimal mock of the PolygonZkEVMBridgeV2 surface that Darwin's
///         AggLayer integration interacts with. Real bridge lives at
///         0xC8cbEBf950B9Df44d987c8619f092beA980fF038 on the
///         gateway-fm/miden-agglayer Anvil; we replicate only the bits
///         Darwin's bridge-out claim flow exercises:
///
///           - `claimAsset(bytes32[32], bytes32[32], uint256, bytes32,
///                         bytes32, uint32, address, uint32, address,
///                         uint256, bytes)` — calls
///             `WrappedBasketToken(originTokenAddress).mint(dest, amount)`
///             once the proof has "passed" (the mock accepts any
///             non-zero leaf hash; production verifies SMT proofs
///             against the configured globalExitRoot).
///
///         The mock lets Foundry exercise the L1 claim leg of Flow A
///         (deposit + claim → mint wDCC) and Flow C (redeem +
///         bridge-out → claim → user receives the underlying assets on
///         L1) without standing up the full docker stack. It's the
///         symmetric L1 counterpart to Darwin's `darwin_bridge_out`
///         binary on the Miden side.
contract MockPolygonZkEVMBridge {
    /// Network id assigned to Miden in the canonical AggLayer config.
    uint32 public constant MIDEN_NETWORK_ID = 1;

    /// Tracks whether a (globalIndex) has already been claimed so the
    /// mock can reject double-claims, matching the production bridge.
    mapping(uint256 => bool) public claimed;

    event ClaimEvent(
        uint256 indexed globalIndex,
        uint32 indexed originNetwork,
        address indexed originToken,
        address destinationAddress,
        uint256 amount
    );

    error AlreadyClaimed(uint256 globalIndex);
    error UnsupportedOriginNetwork(uint32 network);
    error UnsupportedDestinationNetwork(uint32 network);
    error InvalidProofLeaf();
    error MintCallFailed();

    /// @notice Mirror of PolygonZkEVMBridgeV2.claimAsset. The mock
    ///         verifies only the structural invariants Darwin cares
    ///         about (no double-claim, correct networks, non-zero
    ///         proof leaf) and forwards the mint to the supplied
    ///         WrappedBasketToken at `originTokenAddress`.
    function claimAsset(
        bytes32[32] calldata smtProofLocalExitRoot,
        bytes32[32] calldata, /* smtProofRollupExitRoot */
        uint256 globalIndex,
        bytes32, /* mainnetExitRoot */
        bytes32, /* rollupExitRoot */
        uint32 originNetwork,
        address originTokenAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes calldata /* metadata */
    ) external {
        if (claimed[globalIndex]) revert AlreadyClaimed(globalIndex);
        if (originNetwork != MIDEN_NETWORK_ID) revert UnsupportedOriginNetwork(originNetwork);
        if (destinationNetwork != 0) revert UnsupportedDestinationNetwork(destinationNetwork);

        // Sanity-check the proof: at least one leaf must be non-zero.
        // Production verifies the SMT against globalExitRoot; the mock
        // just rejects all-zero proofs so unit tests can pass valid
        // 32-element bytes32 arrays without crashing.
        bool sawNonZeroLeaf;
        for (uint256 i = 0; i < 32; i++) {
            if (smtProofLocalExitRoot[i] != bytes32(0)) {
                sawNonZeroLeaf = true;
                break;
            }
        }
        if (!sawNonZeroLeaf) revert InvalidProofLeaf();

        claimed[globalIndex] = true;

        // Forward to the wrapped basket token.
        try WrappedBasketToken(originTokenAddress).mint(destinationAddress, amount) {
            emit ClaimEvent(
                globalIndex, originNetwork, originTokenAddress, destinationAddress, amount
            );
        } catch {
            revert MintCallFailed();
        }
    }
}
