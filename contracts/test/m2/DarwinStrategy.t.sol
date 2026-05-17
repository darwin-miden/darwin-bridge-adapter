// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DarwinStrategy} from "../../m2/DarwinStrategy.sol";

contract DarwinStrategyTest is Test {
    DarwinStrategy internal strat;
    address internal admin = address(0xA11CE);
    address internal feeRecipient = address(0xFEEFEE);

    address internal dETH = address(0xE701);
    address internal dWBTC = address(0xB701);
    address internal dUSDT = address(0xC701);
    address internal dDAI = address(0xD701);

    function setUp() public {
        vm.prank(admin);
        strat = new DarwinStrategy(admin);
    }

    function _registerDCC() internal returns (bytes32 id) {
        address[] memory tokens = new address[](3);
        tokens[0] = dWBTC;
        tokens[1] = dETH;
        tokens[2] = dUSDT;
        uint16[] memory weights = new uint16[](3);
        weights[0] = 4_000;
        weights[1] = 4_000;
        weights[2] = 2_000;

        vm.prank(admin);
        strat.registerBasket(
            "DCC", tokens, weights, /*driftBps*/ 500, /*mintFee*/ 30, /*redeemFee*/ 30, /*mgmt*/ 100, feeRecipient
        );
        return strat.basketIdOf("DCC");
    }

    function test_registerBasket_persistsAllFields() public {
        bytes32 id = _registerDCC();
        (
            bool registered,
            string memory symbol,
            address[] memory tokens,
            uint16[] memory weights,
            uint16 drift,
            uint16 mintFee,
            uint16 redeemFee,
            uint16 mgmt,
            address recipient,
            uint64 lastTs
        ) = strat.getBasket(id);
        assertTrue(registered);
        assertEq(symbol, "DCC");
        assertEq(tokens.length, 3);
        assertEq(weights.length, 3);
        assertEq(weights[0] + weights[1] + weights[2], 10_000);
        assertEq(drift, 500);
        assertEq(mintFee, 30);
        assertEq(redeemFee, 30);
        assertEq(mgmt, 100);
        assertEq(recipient, feeRecipient);
        assertEq(lastTs, uint64(block.timestamp));
    }

    function test_registerBasket_rejectsDuplicateId() public {
        bytes32 id = _registerDCC();
        address[] memory tokens = new address[](1);
        tokens[0] = dETH;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DarwinStrategy.BasketAlreadyRegistered.selector, id));
        strat.registerBasket("DCC", tokens, weights, 500, 0, 0, 0, feeRecipient);
    }

    function test_registerBasket_rejectsWeightsThatDoNotSumTo10000() public {
        address[] memory tokens = new address[](2);
        tokens[0] = dETH;
        tokens[1] = dWBTC;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 4_000; // sum = 9_000
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DarwinStrategy.WeightsSumMismatch.selector, 9_000, 10_000));
        strat.registerBasket("BAD", tokens, weights, 500, 0, 0, 0, feeRecipient);
    }

    function test_registerBasket_rejectsArrayLengthMismatch() public {
        address[] memory tokens = new address[](2);
        tokens[0] = dETH;
        tokens[1] = dWBTC;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DarwinStrategy.ArrayLengthMismatch.selector, 2, 1));
        strat.registerBasket("BAD", tokens, weights, 500, 0, 0, 0, feeRecipient);
    }

    function test_registerBasket_rejectsEmptyTokenList() public {
        address[] memory tokens = new address[](0);
        uint16[] memory weights = new uint16[](0);
        vm.prank(admin);
        vm.expectRevert(DarwinStrategy.EmptyBasket.selector);
        strat.registerBasket("BAD", tokens, weights, 500, 0, 0, 0, feeRecipient);
    }

    function test_registerBasket_rejectsExcessiveMintFee() public {
        address[] memory tokens = new address[](1);
        tokens[0] = dETH;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(DarwinStrategy.FeeTooHigh.selector, uint16(1_001), uint16(1_000))
        );
        strat.registerBasket("BAD", tokens, weights, 500, 1_001, 0, 0, feeRecipient);
    }

    function test_registerBasket_rejectsExcessiveMgmtFee() public {
        address[] memory tokens = new address[](1);
        tokens[0] = dETH;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DarwinStrategy.FeeTooHigh.selector, uint16(501), uint16(500)));
        strat.registerBasket("BAD", tokens, weights, 500, 0, 0, 501, feeRecipient);
    }

    function test_registerBasket_rejectsZeroFeeRecipient() public {
        address[] memory tokens = new address[](1);
        tokens[0] = dETH;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.prank(admin);
        vm.expectRevert(DarwinStrategy.ZeroAddress.selector);
        strat.registerBasket("BAD", tokens, weights, 500, 0, 0, 0, address(0));
    }

    function test_registerBasket_rejectsZeroTokenAddress() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.prank(admin);
        vm.expectRevert(DarwinStrategy.ZeroAddress.selector);
        strat.registerBasket("BAD", tokens, weights, 500, 0, 0, 0, feeRecipient);
    }

    function test_only_owner_can_register() public {
        address[] memory tokens = new address[](1);
        tokens[0] = dETH;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.prank(address(0xBEEF));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        strat.registerBasket("X", tokens, weights, 500, 0, 0, 0, feeRecipient);
    }

    function test_updateWeights_replacesTokenList() public {
        bytes32 id = _registerDCC();
        address[] memory newTokens = new address[](2);
        newTokens[0] = dETH;
        newTokens[1] = dDAI;
        uint16[] memory newWeights = new uint16[](2);
        newWeights[0] = 6_000;
        newWeights[1] = 4_000;
        vm.prank(admin);
        strat.updateWeights(id, newTokens, newWeights);

        address[] memory tokens = strat.getTokens(id);
        uint16[] memory weights = strat.getTargetWeights(id);
        assertEq(tokens.length, 2);
        assertEq(weights.length, 2);
        assertEq(tokens[0], dETH);
        assertEq(weights[0], 6_000);
        assertEq(weights[1], 4_000);
    }

    function test_updateFees_changesAccessors() public {
        bytes32 id = _registerDCC();
        vm.prank(admin);
        strat.updateFees(id, 50, 75, 200);
        assertEq(strat.getMintFeeBps(id), 50);
        assertEq(strat.getRedeemFeeBps(id), 75);
        assertEq(strat.getManagementFeeBpsAnnual(id), 200);
    }

    function test_updateDriftThreshold_changesAccessor() public {
        bytes32 id = _registerDCC();
        vm.prank(admin);
        strat.updateDriftThreshold(id, 250);
        assertEq(strat.getDriftThresholdBps(id), 250);
    }

    function test_updateFeeRecipient_persistsAndRejectsZero() public {
        bytes32 id = _registerDCC();
        address newRecipient = address(0xCAFE);
        vm.prank(admin);
        strat.updateFeeRecipient(id, newRecipient);
        assertEq(strat.getFeeRecipient(id), newRecipient);

        vm.prank(admin);
        vm.expectRevert(DarwinStrategy.ZeroAddress.selector);
        strat.updateFeeRecipient(id, address(0));
    }

    function test_touchManagementFeeClock_movesTimestampForward() public {
        bytes32 id = _registerDCC();
        uint64 t0 = strat.getLastFeeAccrualUnix(id);
        vm.warp(block.timestamp + 7 days);
        strat.touchManagementFeeClock(id);
        uint64 t1 = strat.getLastFeeAccrualUnix(id);
        assertEq(t1, uint64(block.timestamp));
        assertGt(t1, t0);
    }

    function test_basketCount_and_iteration() public {
        _registerDCC();
        address[] memory tokens = new address[](2);
        tokens[0] = dETH;
        tokens[1] = dWBTC;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        vm.prank(admin);
        strat.registerBasket("DAG", tokens, weights, 400, 30, 30, 50, feeRecipient);

        assertEq(strat.basketCount(), 2);
        assertEq(strat.basketIdAt(0), strat.basketIdOf("DCC"));
        assertEq(strat.basketIdAt(1), strat.basketIdOf("DAG"));
    }
}
