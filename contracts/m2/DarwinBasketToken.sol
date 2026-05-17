// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DarwinStrategy} from "./DarwinStrategy.sol";

/// @title DarwinBasketToken
/// @notice The ETH-side Darwin basket ERC20. Distinct from the M1
///         `WrappedBasketToken`: this is the canonical mint-and-redeem
///         surface for ETH users (paired with the M2 Near Intent /
///         relay-wallet path), not the AggLayer wrapper.
///
/// Mint and redeem are authorised — the protocol mint authority (the
/// AggLayer claim handler or the Near Intent relay) drives `mintTo` /
/// `burnFrom`. End users hold and transfer freely. Fees are skimmed
/// on every mint/redeem and on a time-prorated management-fee tick.
///
/// Grant M2 §1 — basket token mint/burn + fee collection.
contract DarwinBasketToken is ERC20, Ownable {
    DarwinStrategy public immutable strategy;
    bytes32 public immutable basketId;

    /// Year in seconds, used to prorate the annual management fee.
    uint64 public constant SECONDS_PER_YEAR = 365 days;

    event Minted(address indexed to, uint256 grossAmount, uint256 feeAmount);
    event Redeemed(address indexed from, uint256 grossAmount, uint256 feeAmount);
    event ManagementFeeAccrued(uint256 amount, uint64 secondsSinceLast);

    error BasketIdMismatch(bytes32 expected, bytes32 got);
    error ZeroAmount();

    constructor(
        string memory name_,
        string memory symbol_,
        DarwinStrategy strategy_,
        bytes32 basketId_,
        address protocolMintAuthority
    ) ERC20(name_, symbol_) Ownable(protocolMintAuthority) {
        strategy = strategy_;
        basketId = basketId_;
        // sanity: the strategy must know this basket
        (bool registered, , , , , , , , , ) = strategy_.getBasket(basketId_);
        if (!registered) revert BasketIdMismatch(basketId_, bytes32(0));
    }

    /// Mint `grossAmount` worth of basket tokens for `to`. Mint fee is
    /// skimmed and routed to the strategy's fee recipient. Net amount
    /// is what `to` actually receives.
    ///
    /// Returns (netMintedToUser, feeMintedToRecipient).
    function mintTo(address to, uint256 grossAmount)
        external
        onlyOwner
        returns (uint256 netMinted, uint256 feeMinted)
    {
        if (grossAmount == 0) revert ZeroAmount();
        _accrueManagementFee();
        uint256 fee = (grossAmount * strategy.getMintFeeBps(basketId)) / strategy.BPS_TOTAL();
        uint256 net = grossAmount - fee;
        if (fee > 0) {
            _mint(strategy.getFeeRecipient(basketId), fee);
        }
        _mint(to, net);
        emit Minted(to, grossAmount, fee);
        return (net, fee);
    }

    /// Burn `grossAmount` from `from` after skimming the redeem fee.
    /// Returns (netBurned, feeMintedToRecipient).
    function burnFrom(address from, uint256 grossAmount)
        external
        onlyOwner
        returns (uint256 netBurned, uint256 feeMinted)
    {
        if (grossAmount == 0) revert ZeroAmount();
        _accrueManagementFee();
        uint256 fee =
            (grossAmount * strategy.getRedeemFeeBps(basketId)) / strategy.BPS_TOTAL();
        uint256 net = grossAmount - fee;
        // pay the fee in basket-token units to the recipient
        _burn(from, grossAmount);
        if (fee > 0) {
            _mint(strategy.getFeeRecipient(basketId), fee);
        }
        emit Redeemed(from, grossAmount, fee);
        return (net, fee);
    }

    /// External hook so anyone can trigger management-fee accrual
    /// without waiting for a mint/redeem. The fee mints diluting
    /// shares to the recipient at `(annualBps * elapsedSeconds /
    /// SECONDS_PER_YEAR) * totalSupply`.
    function accrueManagementFee() external returns (uint256 mintedToRecipient) {
        return _accrueManagementFee();
    }

    function _accrueManagementFee() internal returns (uint256 mintedToRecipient) {
        uint16 annualBps = strategy.getManagementFeeBpsAnnual(basketId);
        if (annualBps == 0) return 0;
        uint256 supply = totalSupply();
        if (supply == 0) {
            strategy.touchManagementFeeClock(basketId);
            return 0;
        }
        uint64 last = strategy.getLastFeeAccrualUnix(basketId);
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs <= last) return 0;
        uint64 elapsed = nowTs - last;
        // annualBps / 10_000 * elapsed / SECONDS_PER_YEAR * supply
        uint256 fee =
            (supply * uint256(annualBps) * uint256(elapsed))
                / (uint256(strategy.BPS_TOTAL()) * uint256(SECONDS_PER_YEAR));
        strategy.touchManagementFeeClock(basketId);
        if (fee == 0) return 0;
        _mint(strategy.getFeeRecipient(basketId), fee);
        emit ManagementFeeAccrued(fee, elapsed);
        return fee;
    }
}
