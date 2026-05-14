// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WrappedBasketToken} from "../WrappedBasketToken.sol";

contract WrappedBasketTokenTest is Test {
    WrappedBasketToken internal wdcc;

    // Test fixtures — vm.addr() returns deterministic, checksum-clean
    // addresses derived from a private key seed.
    address internal bridge = vm.addr(0xB1D6E);
    address internal user = vm.addr(0xD4EC0E);

    // Synthetic Miden-origin token address for the DCC basket
    // (placeholder — production derives this from
    //  Keccak256("darwin:DCC:" || basket_faucet_id) truncated to 20 bytes).
    address internal constant MIDEN_ORIGIN = address(0x0000000000000000000000000000000000000dCC);
    uint32 internal constant MIDEN_NETWORK = 2;

    function setUp() public {
        wdcc = new WrappedBasketToken(
            "Wrapped Darwin Core Crypto",
            "wDCC",
            MIDEN_ORIGIN,
            MIDEN_NETWORK,
            bridge
        );
    }

    function test_initial_supply_is_zero() public view {
        assertEq(wdcc.totalSupply(), 0);
    }

    function test_owner_is_bridge() public view {
        assertEq(wdcc.owner(), bridge);
    }

    function test_metadata_records_miden_origin() public view {
        assertEq(wdcc.midenOriginToken(), MIDEN_ORIGIN);
        assertEq(wdcc.midenNetworkId(), MIDEN_NETWORK);
        assertEq(wdcc.name(), "Wrapped Darwin Core Crypto");
        assertEq(wdcc.symbol(), "wDCC");
    }

    function test_only_bridge_can_mint() public {
        // Anyone else reverts on Ownable's onlyOwner.
        vm.prank(user);
        vm.expectRevert();
        wdcc.mint(user, 1000);
    }

    function test_bridge_can_mint_to_user() public {
        vm.prank(bridge);
        wdcc.mint(user, 1000);
        assertEq(wdcc.balanceOf(user), 1000);
        assertEq(wdcc.totalSupply(), 1000);
    }

    function test_bridge_can_burn_from_user() public {
        vm.prank(bridge);
        wdcc.mint(user, 1000);

        vm.prank(bridge);
        wdcc.burnFrom(user, 400);

        assertEq(wdcc.balanceOf(user), 600);
        assertEq(wdcc.totalSupply(), 600);
    }

    function test_user_cannot_burn_their_own() public {
        vm.prank(bridge);
        wdcc.mint(user, 1000);

        // burnFrom is onlyOwner — the user's own call reverts.
        vm.prank(user);
        vm.expectRevert();
        wdcc.burnFrom(user, 100);
    }

    function test_mint_then_burn_round_trip_preserves_zero_supply() public {
        vm.startPrank(bridge);
        wdcc.mint(user, 1234);
        wdcc.burnFrom(user, 1234);
        vm.stopPrank();

        assertEq(wdcc.balanceOf(user), 0);
        assertEq(wdcc.totalSupply(), 0);
    }
}
