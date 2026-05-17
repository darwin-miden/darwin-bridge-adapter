// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {DarwinStrategy} from "../m2/DarwinStrategy.sol";
import {DarwinBasketToken} from "../m2/DarwinBasketToken.sol";

/// @notice One-shot Sepolia deploy of the M2 strategy + the three M1
///         basket tokens (DCC, DAG, DCO) registered with placeholder
///         constituent addresses + zero fees so a relay-side run can
///         exercise the mint path end-to-end.
///
/// Required env:
///   PRIVATE_KEY           Deployer EOA. Becomes the strategy admin
///                         AND the protocol mint authority on every
///                         basket-token (so the relay can mint as
///                         the same EOA in dev).
///
/// Optional env:
///   MINT_AUTHORITY        Address allowed to call mintTo on each
///                         basket-token. Defaults to deployer.
///   FEE_RECIPIENT         Address paid the mint/redeem/mgmt fees.
///                         Defaults to deployer.
///   PLACEHOLDER_CONSTITUENT  Address used as the per-token entry
///                         in DarwinStrategy.registerBasket. The
///                         strategy only checks token != 0 and
///                         weights sum to 10_000 — actual
///                         constituent ERC20s land later. Defaults
///                         to deployer.
///
/// Usage:
///   forge script contracts/script/DeployM2Stack.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --broadcast
contract DeployM2Stack is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address mintAuth = _envAddressOr("MINT_AUTHORITY", deployer);
        address feeRecipient = _envAddressOr("FEE_RECIPIENT", deployer);
        address placeholderToken = _envAddressOr("PLACEHOLDER_CONSTITUENT", deployer);

        vm.startBroadcast(deployerKey);

        DarwinStrategy strategy = new DarwinStrategy(deployer);
        console2.log("DarwinStrategy:", address(strategy));

        // DCC — 3 constituents at 40/40/20 (placeholders).
        bytes32 dccId = _registerBasket(
            strategy,
            "DCC",
            _three(placeholderToken),
            _weights3(4_000, 4_000, 2_000),
            500,
            feeRecipient
        );
        DarwinBasketToken dcc = new DarwinBasketToken(
            "Darwin Core Crypto",
            "DCC",
            strategy,
            dccId,
            mintAuth
        );
        console2.log("DCC token:    ", address(dcc));

        // DAG — 2 constituents at 50/50.
        bytes32 dagId = _registerBasket(
            strategy,
            "DAG",
            _two(placeholderToken),
            _weights2(5_000, 5_000),
            500,
            feeRecipient
        );
        DarwinBasketToken dag = new DarwinBasketToken(
            "Darwin Aggressive",
            "DAG",
            strategy,
            dagId,
            mintAuth
        );
        console2.log("DAG token:    ", address(dag));

        // DCO — 4 constituents at 10/10/40/40.
        bytes32 dcoId = _registerBasket(
            strategy,
            "DCO",
            _four(placeholderToken),
            _weights4(1_000, 1_000, 4_000, 4_000),
            500,
            feeRecipient
        );
        DarwinBasketToken dco = new DarwinBasketToken(
            "Darwin Conservative",
            "DCO",
            strategy,
            dcoId,
            mintAuth
        );
        console2.log("DCO token:    ", address(dco));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== M2 stack deployed ===");
        console2.log("Strategy:", address(strategy));
        console2.log("DCC:     ", address(dcc));
        console2.log("DAG:     ", address(dag));
        console2.log("DCO:     ", address(dco));
        console2.log("");
        console2.log("BasketRegistry pairs for darwin-relay DARWIN_RELAY_ETH_BASKETS:");
        console2.log("  basketId (DCC):");
        console2.logBytes32(dccId);
        console2.log("  token:");
        console2.log(address(dcc));
        console2.log("  basketId (DAG):");
        console2.logBytes32(dagId);
        console2.log("  token:");
        console2.log(address(dag));
        console2.log("  basketId (DCO):");
        console2.logBytes32(dcoId);
        console2.log("  token:");
        console2.log(address(dco));
    }

    function _registerBasket(
        DarwinStrategy strategy,
        string memory symbol,
        address[] memory tokens,
        uint16[] memory weights,
        uint16 driftBps,
        address feeRecipient
    ) internal returns (bytes32) {
        // Mint/redeem fees set to 30 bps so the relay mint-path is
        // exercised with a real fee skim; management fee at 100 bps/yr.
        strategy.registerBasket(symbol, tokens, weights, driftBps, 30, 30, 100, feeRecipient);
        return strategy.basketIdOf(symbol);
    }

    function _envAddressOr(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address a) {
            return a;
        } catch {
            return fallback_;
        }
    }

    function _two(address a) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = a;
    }

    function _three(address a) internal pure returns (address[] memory out) {
        out = new address[](3);
        out[0] = a;
        out[1] = a;
        out[2] = a;
    }

    function _four(address a) internal pure returns (address[] memory out) {
        out = new address[](4);
        out[0] = a;
        out[1] = a;
        out[2] = a;
        out[3] = a;
    }

    function _weights2(uint16 a, uint16 b) internal pure returns (uint16[] memory out) {
        out = new uint16[](2);
        out[0] = a;
        out[1] = b;
    }

    function _weights3(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory out) {
        out = new uint16[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _weights4(uint16 a, uint16 b, uint16 c, uint16 d)
        internal
        pure
        returns (uint16[] memory out)
    {
        out = new uint16[](4);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
    }
}
