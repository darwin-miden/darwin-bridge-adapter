// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WrappedBasketToken} from "../WrappedBasketToken.sol";
import {MockPolygonZkEVMBridge} from "./MockPolygonZkEVMBridge.sol";

/// @title BridgeClaimRoundTripTest
/// @notice Exercises the L1 leg of AggLayer BridgeAsset end-to-end:
///         the bridge calls `WrappedBasketToken.mint` on a successful
///         claim, the destination receives the wrapped basket token,
///         and the supply / balance bookkeeping matches what Darwin's
///         on-chain spec section 10.5 mandates.
///
/// What this covers without a live bridge: Darwin's L1-side contract
/// surface — the same one the canonical PolygonZkEVMBridgeV2 calls
/// into when an AggLayer certificate settles. If a real
/// `claimAsset` lands, this is the code path it ends up exercising.
contract BridgeClaimRoundTripTest is Test {
    MockPolygonZkEVMBridge internal bridge;
    WrappedBasketToken internal wdcc;

    address internal user = vm.addr(0xD4EC0E);
    address internal otherUser = vm.addr(0xA1A1);

    address internal constant DCC_MIDEN_ORIGIN =
        address(0x0000000000000000000000000000000000000dCC);
    uint32 internal constant MIDEN_NETWORK = 1;
    uint32 internal constant L1_NETWORK = 0;

    function setUp() public {
        bridge = new MockPolygonZkEVMBridge();
        wdcc = new WrappedBasketToken(
            "Wrapped Darwin Core Crypto",
            "wDCC",
            DCC_MIDEN_ORIGIN,
            MIDEN_NETWORK,
            address(bridge)
        );
    }

    // -- Helpers -----------------------------------------------------------

    /// Returns a proof array whose first leaf is non-zero (everything
    /// the mock checks). Production replaces this with the real
    /// merkle-proof entries from bridge-service.
    function _validProof() internal pure returns (bytes32[32] memory proof) {
        proof[0] = bytes32(uint256(0x1));
    }

    // -- Core happy path ---------------------------------------------------

    function test_claim_mints_wdcc_to_destination() public {
        bytes32[32] memory smtLocal = _validProof();
        bytes32[32] memory smtRollup = _validProof();

        bridge.claimAsset(
            smtLocal,
            smtRollup,
            42,
            bytes32(uint256(0xa)),
            bytes32(uint256(0xb)),
            MIDEN_NETWORK,
            address(wdcc),
            L1_NETWORK,
            user,
            1000,
            ""
        );

        assertEq(wdcc.balanceOf(user), 1000, "destination should hold wDCC");
        assertEq(wdcc.totalSupply(), 1000, "supply tracks the mint");
        assertTrue(bridge.claimed(42), "claim recorded");
    }

    function test_claim_emits_event() public {
        bytes32[32] memory proof = _validProof();

        vm.expectEmit(true, true, true, true);
        emit MockPolygonZkEVMBridge.ClaimEvent(42, MIDEN_NETWORK, address(wdcc), user, 1000);

        bridge.claimAsset(
            proof, proof, 42, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), L1_NETWORK, user, 1000, ""
        );
    }

    // -- Replay protection -------------------------------------------------

    function test_double_claim_reverts() public {
        bytes32[32] memory proof = _validProof();
        bridge.claimAsset(
            proof, proof, 7, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), L1_NETWORK, user, 100, ""
        );

        vm.expectRevert(
            abi.encodeWithSelector(MockPolygonZkEVMBridge.AlreadyClaimed.selector, uint256(7))
        );
        bridge.claimAsset(
            proof, proof, 7, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), L1_NETWORK, user, 100, ""
        );

        // Balance unchanged after the failed replay.
        assertEq(wdcc.balanceOf(user), 100);
    }

    // -- Network gating ----------------------------------------------------

    function test_claim_rejects_wrong_origin_network() public {
        bytes32[32] memory proof = _validProof();
        vm.expectRevert(
            abi.encodeWithSelector(MockPolygonZkEVMBridge.UnsupportedOriginNetwork.selector, uint32(99))
        );
        bridge.claimAsset(
            proof, proof, 1, bytes32(uint256(1)), bytes32(uint256(2)),
            99, address(wdcc), L1_NETWORK, user, 100, ""
        );
    }

    function test_claim_rejects_wrong_destination_network() public {
        bytes32[32] memory proof = _validProof();
        vm.expectRevert(
            abi.encodeWithSelector(
                MockPolygonZkEVMBridge.UnsupportedDestinationNetwork.selector, uint32(2)
            )
        );
        bridge.claimAsset(
            proof, proof, 1, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), 2, user, 100, ""
        );
    }

    function test_claim_rejects_empty_proof() public {
        bytes32[32] memory emptyProof; // all zero
        vm.expectRevert(MockPolygonZkEVMBridge.InvalidProofLeaf.selector);
        bridge.claimAsset(
            emptyProof, emptyProof, 1, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), L1_NETWORK, user, 100, ""
        );
    }

    // -- Bridge owns mint/burn ---------------------------------------------

    function test_only_bridge_can_mint_via_wdcc_directly() public {
        // The wDCC's owner is the bridge, so a direct mint from a
        // random caller reverts even if the proof was valid.
        vm.prank(user);
        vm.expectRevert();
        wdcc.mint(user, 100);
    }

    function test_bridge_can_burn_during_l1_to_l2_bridge_in() public {
        // First mint via claim, then bridge-in (burn) the same amount.
        bytes32[32] memory proof = _validProof();
        bridge.claimAsset(
            proof, proof, 9, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), L1_NETWORK, user, 1000, ""
        );
        assertEq(wdcc.balanceOf(user), 1000);

        // Bridge burns the user's wDCC on bridge-in to Miden.
        vm.prank(address(bridge));
        wdcc.burnFrom(user, 400);

        assertEq(wdcc.balanceOf(user), 600);
        assertEq(wdcc.totalSupply(), 600);
    }

    // -- Multiple claims fan out -------------------------------------------

    function test_multiple_claims_to_different_users_track_supply() public {
        bytes32[32] memory proof = _validProof();

        bridge.claimAsset(
            proof, proof, 10, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), L1_NETWORK, user, 250, ""
        );
        bridge.claimAsset(
            proof, proof, 11, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), L1_NETWORK, otherUser, 750, ""
        );

        assertEq(wdcc.balanceOf(user), 250);
        assertEq(wdcc.balanceOf(otherUser), 750);
        assertEq(wdcc.totalSupply(), 1000);
    }

    // -- Round-trip net-zero invariant -------------------------------------

    function test_claim_then_full_burn_returns_to_zero_supply() public {
        bytes32[32] memory proof = _validProof();
        bridge.claimAsset(
            proof, proof, 99, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), L1_NETWORK, user, 12345, ""
        );
        assertEq(wdcc.totalSupply(), 12345);

        vm.prank(address(bridge));
        wdcc.burnFrom(user, 12345);

        assertEq(wdcc.totalSupply(), 0);
        assertEq(wdcc.balanceOf(user), 0);
    }

    // -- Standard ERC20 surface is unrestricted ----------------------------

    function test_user_can_transfer_claimed_wdcc_freely() public {
        bytes32[32] memory proof = _validProof();
        bridge.claimAsset(
            proof, proof, 5, bytes32(uint256(1)), bytes32(uint256(2)),
            MIDEN_NETWORK, address(wdcc), L1_NETWORK, user, 1000, ""
        );

        vm.prank(user);
        wdcc.transfer(otherUser, 333);

        assertEq(wdcc.balanceOf(user), 667);
        assertEq(wdcc.balanceOf(otherUser), 333);
    }
}
