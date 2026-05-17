// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title DarwinStrategy
/// @notice On-chain registry of every Darwin basket's strategy
///         parameters: constituent token addresses, target weights
///         (basis points, sum to 10_000), rebalancing rules
///         (drift threshold), and the fee structure. The mirror of the
///         on-Miden `darwin-baskets` manifests for the ETH side.
///
/// One instance covers every basket Darwin operates. Each basket is
/// keyed by `bytes32 basketId = keccak256(symbol)`. The Darwin admin
/// (set at deployment, transferable) is the only address that can
/// register or modify a basket.
///
/// Grant M2 §1 — "strategy storage (token list, target weights,
/// rebalancing rules, fee structure), NAV reference".
contract DarwinStrategy is Ownable {
    /// One entry per basket. `tokens` and `targetWeightsBps` are
    /// parallel arrays — index i is the weight of token i. Sum of
    /// `targetWeightsBps` must equal `BPS_TOTAL` (10_000).
    struct Basket {
        bool registered;
        string symbol;
        address[] tokens;
        uint16[] targetWeightsBps;
        uint16 driftThresholdBps;
        uint16 mintFeeBps;
        uint16 redeemFeeBps;
        uint16 managementFeeBpsAnnual;
        address feeRecipient;
        uint64 lastFeeAccrualUnix;
    }

    uint16 public constant BPS_TOTAL = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000; // cap any single fee at 10%
    uint16 public constant MAX_MANAGEMENT_FEE_BPS_ANNUAL = 500; // 5% / yr

    mapping(bytes32 => Basket) private _baskets;
    bytes32[] private _basketIds;

    event BasketRegistered(bytes32 indexed basketId, string symbol);
    event BasketWeightsUpdated(bytes32 indexed basketId);
    event BasketFeesUpdated(bytes32 indexed basketId);
    event BasketDriftThresholdUpdated(bytes32 indexed basketId, uint16 driftBps);
    event FeeRecipientUpdated(bytes32 indexed basketId, address recipient);

    error BasketAlreadyRegistered(bytes32 basketId);
    error BasketNotRegistered(bytes32 basketId);
    error WeightsSumMismatch(uint256 got, uint256 expected);
    error ArrayLengthMismatch(uint256 tokens, uint256 weights);
    error EmptyBasket();
    error FeeTooHigh(uint16 got, uint16 cap);
    error ZeroAddress();

    constructor(address admin) Ownable(admin) {
        if (admin == address(0)) revert ZeroAddress();
    }

    /// Compute the canonical basket id from a symbol ("DCC", "DAG", "DCO").
    function basketIdOf(string memory symbol) public pure returns (bytes32) {
        return keccak256(bytes(symbol));
    }

    /// Register a new basket. Reverts if the basket id already exists or
    /// if any input fails validation.
    function registerBasket(
        string calldata symbol,
        address[] calldata tokens,
        uint16[] calldata targetWeightsBps,
        uint16 driftThresholdBps,
        uint16 mintFeeBps,
        uint16 redeemFeeBps,
        uint16 managementFeeBpsAnnual,
        address feeRecipient
    ) external onlyOwner {
        bytes32 id = basketIdOf(symbol);
        if (_baskets[id].registered) revert BasketAlreadyRegistered(id);
        _validateBasket(
            tokens,
            targetWeightsBps,
            mintFeeBps,
            redeemFeeBps,
            managementFeeBpsAnnual,
            feeRecipient
        );

        Basket storage b = _baskets[id];
        b.registered = true;
        b.symbol = symbol;
        for (uint256 i = 0; i < tokens.length; i++) {
            b.tokens.push(tokens[i]);
            b.targetWeightsBps.push(targetWeightsBps[i]);
        }
        b.driftThresholdBps = driftThresholdBps;
        b.mintFeeBps = mintFeeBps;
        b.redeemFeeBps = redeemFeeBps;
        b.managementFeeBpsAnnual = managementFeeBpsAnnual;
        b.feeRecipient = feeRecipient;
        b.lastFeeAccrualUnix = uint64(block.timestamp);

        _basketIds.push(id);
        emit BasketRegistered(id, symbol);
    }

    /// Replace the token list + target weights for an existing basket.
    /// Used when rebalancing rules change (e.g. constituent swap).
    function updateWeights(
        bytes32 basketId,
        address[] calldata tokens,
        uint16[] calldata targetWeightsBps
    ) external onlyOwner {
        Basket storage b = _requireBasket(basketId);
        if (tokens.length != targetWeightsBps.length) {
            revert ArrayLengthMismatch(tokens.length, targetWeightsBps.length);
        }
        if (tokens.length == 0) revert EmptyBasket();
        uint256 sum;
        for (uint256 i = 0; i < targetWeightsBps.length; i++) {
            sum += targetWeightsBps[i];
            if (tokens[i] == address(0)) revert ZeroAddress();
        }
        if (sum != BPS_TOTAL) revert WeightsSumMismatch(sum, BPS_TOTAL);

        delete b.tokens;
        delete b.targetWeightsBps;
        for (uint256 i = 0; i < tokens.length; i++) {
            b.tokens.push(tokens[i]);
            b.targetWeightsBps.push(targetWeightsBps[i]);
        }
        emit BasketWeightsUpdated(basketId);
    }

    function updateFees(
        bytes32 basketId,
        uint16 mintFeeBps,
        uint16 redeemFeeBps,
        uint16 managementFeeBpsAnnual
    ) external onlyOwner {
        Basket storage b = _requireBasket(basketId);
        if (mintFeeBps > MAX_FEE_BPS) revert FeeTooHigh(mintFeeBps, MAX_FEE_BPS);
        if (redeemFeeBps > MAX_FEE_BPS) revert FeeTooHigh(redeemFeeBps, MAX_FEE_BPS);
        if (managementFeeBpsAnnual > MAX_MANAGEMENT_FEE_BPS_ANNUAL) {
            revert FeeTooHigh(managementFeeBpsAnnual, MAX_MANAGEMENT_FEE_BPS_ANNUAL);
        }
        b.mintFeeBps = mintFeeBps;
        b.redeemFeeBps = redeemFeeBps;
        b.managementFeeBpsAnnual = managementFeeBpsAnnual;
        emit BasketFeesUpdated(basketId);
    }

    function updateDriftThreshold(bytes32 basketId, uint16 driftBps) external onlyOwner {
        Basket storage b = _requireBasket(basketId);
        b.driftThresholdBps = driftBps;
        emit BasketDriftThresholdUpdated(basketId, driftBps);
    }

    function updateFeeRecipient(bytes32 basketId, address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        Basket storage b = _requireBasket(basketId);
        b.feeRecipient = recipient;
        emit FeeRecipientUpdated(basketId, recipient);
    }

    /// Called by the basket token's mint/redeem path after fees have
    /// been collected. Anchors the management-fee accrual clock so the
    /// next call doesn't double-charge.
    function touchManagementFeeClock(bytes32 basketId) external {
        Basket storage b = _requireBasket(basketId);
        b.lastFeeAccrualUnix = uint64(block.timestamp);
    }

    // ------------- views -------------

    function basketCount() external view returns (uint256) {
        return _basketIds.length;
    }

    function basketIdAt(uint256 index) external view returns (bytes32) {
        return _basketIds[index];
    }

    function getBasket(bytes32 basketId)
        external
        view
        returns (
            bool registered,
            string memory symbol,
            address[] memory tokens,
            uint16[] memory targetWeightsBps,
            uint16 driftThresholdBps,
            uint16 mintFeeBps,
            uint16 redeemFeeBps,
            uint16 managementFeeBpsAnnual,
            address feeRecipient,
            uint64 lastFeeAccrualUnix
        )
    {
        Basket storage b = _baskets[basketId];
        return (
            b.registered,
            b.symbol,
            b.tokens,
            b.targetWeightsBps,
            b.driftThresholdBps,
            b.mintFeeBps,
            b.redeemFeeBps,
            b.managementFeeBpsAnnual,
            b.feeRecipient,
            b.lastFeeAccrualUnix
        );
    }

    function getTokens(bytes32 basketId) external view returns (address[] memory) {
        return _requireBasketView(basketId).tokens;
    }

    function getTargetWeights(bytes32 basketId) external view returns (uint16[] memory) {
        return _requireBasketView(basketId).targetWeightsBps;
    }

    function getMintFeeBps(bytes32 basketId) external view returns (uint16) {
        return _requireBasketView(basketId).mintFeeBps;
    }

    function getRedeemFeeBps(bytes32 basketId) external view returns (uint16) {
        return _requireBasketView(basketId).redeemFeeBps;
    }

    function getManagementFeeBpsAnnual(bytes32 basketId) external view returns (uint16) {
        return _requireBasketView(basketId).managementFeeBpsAnnual;
    }

    function getFeeRecipient(bytes32 basketId) external view returns (address) {
        return _requireBasketView(basketId).feeRecipient;
    }

    function getDriftThresholdBps(bytes32 basketId) external view returns (uint16) {
        return _requireBasketView(basketId).driftThresholdBps;
    }

    function getLastFeeAccrualUnix(bytes32 basketId) external view returns (uint64) {
        return _requireBasketView(basketId).lastFeeAccrualUnix;
    }

    // ------------- internals -------------

    function _validateBasket(
        address[] calldata tokens,
        uint16[] calldata targetWeightsBps,
        uint16 mintFeeBps,
        uint16 redeemFeeBps,
        uint16 managementFeeBpsAnnual,
        address feeRecipient
    ) internal pure {
        if (tokens.length == 0) revert EmptyBasket();
        if (tokens.length != targetWeightsBps.length) {
            revert ArrayLengthMismatch(tokens.length, targetWeightsBps.length);
        }
        if (feeRecipient == address(0)) revert ZeroAddress();
        if (mintFeeBps > MAX_FEE_BPS) revert FeeTooHigh(mintFeeBps, MAX_FEE_BPS);
        if (redeemFeeBps > MAX_FEE_BPS) revert FeeTooHigh(redeemFeeBps, MAX_FEE_BPS);
        if (managementFeeBpsAnnual > MAX_MANAGEMENT_FEE_BPS_ANNUAL) {
            revert FeeTooHigh(managementFeeBpsAnnual, MAX_MANAGEMENT_FEE_BPS_ANNUAL);
        }
        uint256 sum;
        for (uint256 i = 0; i < targetWeightsBps.length; i++) {
            sum += targetWeightsBps[i];
            if (tokens[i] == address(0)) revert ZeroAddress();
        }
        if (sum != BPS_TOTAL) revert WeightsSumMismatch(sum, BPS_TOTAL);
    }

    function _requireBasket(bytes32 basketId) internal view returns (Basket storage b) {
        b = _baskets[basketId];
        if (!b.registered) revert BasketNotRegistered(basketId);
    }

    function _requireBasketView(bytes32 basketId) internal view returns (Basket storage b) {
        return _requireBasket(basketId);
    }
}
