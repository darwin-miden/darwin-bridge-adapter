// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DarwinStrategy} from "../../m2/DarwinStrategy.sol";
import {DarwinBasketToken} from "../../m2/DarwinBasketToken.sol";

contract DarwinBasketTokenTest is Test {
    DarwinStrategy internal strat;
    DarwinBasketToken internal dccToken;
    bytes32 internal dccId;

    address internal admin = address(0xA11CE);
    address internal mintAuth = address(0xC0FFEE);
    address internal feeRecipient = address(0xFEEFEE);
    address internal user = address(0xBEEF);

    function setUp() public {
        vm.prank(admin);
        strat = new DarwinStrategy(admin);

        address[] memory tokens = new address[](3);
        tokens[0] = address(0xE701);
        tokens[1] = address(0xB701);
        tokens[2] = address(0xC701);
        uint16[] memory weights = new uint16[](3);
        weights[0] = 4_000;
        weights[1] = 4_000;
        weights[2] = 2_000;
        vm.prank(admin);
        strat.registerBasket(
            "DCC", tokens, weights, /*driftBps*/ 500, /*mintFee*/ 30, /*redeemFee*/ 50, /*mgmt*/ 100, feeRecipient
        );
        dccId = strat.basketIdOf("DCC");
        dccToken = new DarwinBasketToken("Darwin Core Crypto", "DCC", strat, dccId, mintAuth);
    }

    function test_constructor_initialState() public view {
        assertEq(dccToken.name(), "Darwin Core Crypto");
        assertEq(dccToken.symbol(), "DCC");
        assertEq(address(dccToken.strategy()), address(strat));
        assertEq(dccToken.basketId(), dccId);
        assertEq(dccToken.owner(), mintAuth);
        assertEq(dccToken.totalSupply(), 0);
    }

    function test_constructor_revertsOnUnknownBasketId() public {
        vm.expectRevert(
            abi.encodeWithSelector(DarwinBasketToken.BasketIdMismatch.selector, bytes32(uint256(0xdead)), bytes32(0))
        );
        new DarwinBasketToken("X", "X", strat, bytes32(uint256(0xdead)), mintAuth);
    }

    function test_mintTo_skimsMintFeeAndRoutesToRecipient() public {
        vm.prank(mintAuth);
        (uint256 net, uint256 fee) = dccToken.mintTo(user, 10_000);
        // mintFee = 30 bps → 30 fee, 9_970 net
        assertEq(fee, 30);
        assertEq(net, 9_970);
        assertEq(dccToken.balanceOf(user), 9_970);
        assertEq(dccToken.balanceOf(feeRecipient), 30);
        assertEq(dccToken.totalSupply(), 10_000);
    }

    function test_mintTo_rejectsZeroAmount() public {
        vm.prank(mintAuth);
        vm.expectRevert(DarwinBasketToken.ZeroAmount.selector);
        dccToken.mintTo(user, 0);
    }

    function test_mintTo_onlyOwnerCanMint() public {
        vm.prank(user);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        dccToken.mintTo(user, 1_000);
    }

    function test_burnFrom_skimsRedeemFeeAndMintsToRecipient() public {
        // first mint a fresh supply
        vm.prank(mintAuth);
        dccToken.mintTo(user, 10_000);
        uint256 supplyBefore = dccToken.totalSupply();
        uint256 userBefore = dccToken.balanceOf(user);
        uint256 recipientBefore = dccToken.balanceOf(feeRecipient);

        vm.prank(mintAuth);
        (uint256 net, uint256 fee) = dccToken.burnFrom(user, 5_000);
        // redeemFee = 50 bps → fee = 25, net underlying = 4_975
        assertEq(fee, 25);
        assertEq(net, 4_975);
        assertEq(dccToken.balanceOf(user), userBefore - 5_000);
        assertEq(dccToken.balanceOf(feeRecipient), recipientBefore + 25);
        // totalSupply effect: -5_000 burn + 25 mint to recipient
        assertEq(dccToken.totalSupply(), supplyBefore - 5_000 + 25);
    }

    function test_burnFrom_onlyOwnerCanBurn() public {
        vm.prank(mintAuth);
        dccToken.mintTo(user, 1_000);
        vm.prank(user);
        vm.expectRevert();
        dccToken.burnFrom(user, 100);
    }

    function test_managementFee_accruesProRataAfterOneYear() public {
        // mint a clean 1_000_000 supply
        vm.prank(mintAuth);
        dccToken.mintTo(user, 1_000_000);
        // mintFee skim = 3_000 (30 bps). Real supply = 1_000_000.
        uint256 supplyBefore = dccToken.totalSupply();

        // 1 year later
        vm.warp(block.timestamp + 365 days);
        uint256 minted = dccToken.accrueManagementFee();
        // 100 bps annual on supplyBefore = supplyBefore / 100
        uint256 expected = supplyBefore * 100 / 10_000;
        assertEq(minted, expected, "minted fee");
        assertEq(dccToken.totalSupply(), supplyBefore + expected);
    }

    function test_managementFee_zeroWhenSupplyZero() public {
        // no mint yet, supply is 0
        vm.warp(block.timestamp + 365 days);
        uint256 minted = dccToken.accrueManagementFee();
        assertEq(minted, 0);
    }

    function test_managementFee_idempotentSameBlock() public {
        vm.prank(mintAuth);
        dccToken.mintTo(user, 1_000_000);

        vm.warp(block.timestamp + 30 days);
        uint256 minted1 = dccToken.accrueManagementFee();
        // calling again at the same block must mint nothing
        uint256 minted2 = dccToken.accrueManagementFee();
        assertGt(minted1, 0);
        assertEq(minted2, 0);
    }

    function test_managementFee_isAccruedOnMint() public {
        vm.prank(mintAuth);
        dccToken.mintTo(user, 1_000_000);
        uint256 supplyAfterFirstMint = dccToken.totalSupply();

        // a full year later the next mint should accrue 1% mgmt + skim its own 30 bps mint fee
        vm.warp(block.timestamp + 365 days);
        vm.prank(mintAuth);
        dccToken.mintTo(user, 100_000);

        // mgmt accrual on supplyAfterFirstMint (1%) + new mint of 100_000 (30 bps to recipient)
        uint256 expectedMgmtFee = supplyAfterFirstMint * 100 / 10_000;
        uint256 expectedSupply = supplyAfterFirstMint + expectedMgmtFee + 100_000;
        assertEq(dccToken.totalSupply(), expectedSupply);
    }

    function test_strategyHandle_pointsAtRegistry() public view {
        // the basket token should expose its strategy + id so an
        // off-chain rebalance bot can discover everything via the
        // token contract alone.
        assertEq(address(dccToken.strategy()), address(strat));
        assertEq(dccToken.basketId(), strat.basketIdOf("DCC"));
    }
}
