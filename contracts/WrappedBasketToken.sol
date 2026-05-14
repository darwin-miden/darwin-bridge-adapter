// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title WrappedBasketToken
/// @notice L1 ERC20 representation of a Darwin basket token bridged out
///         via the AggLayer Unified Bridge. The owner is the AggLayer
///         Unified Bridge contract, which mints when a leaf is claimed
///         on L1 and burns when a corresponding `bridgeAsset` re-locks
///         the token on its way back to Miden.
///
/// Production deployments (`wDCC`, `wDAG`, `wDCO`) ship with the M3
/// mainnet launch. For M1 testnet, instances of this contract are used
/// as the L1 endpoint when exercising the bridge against the
/// `gateway-fm/miden-agglayer` docker-compose stack.
contract WrappedBasketToken is ERC20, Ownable {
    /// Synthetic Miden-origin token address that this wrapper
    /// corresponds to. The basket faucet on Miden derives this address
    /// from `Keccak256("darwin:" || symbol)[0..20]`.
    address public immutable midenOriginToken;

    /// AggLayer network id of the origin (= Miden's network id).
    uint32 public immutable midenNetworkId;

    constructor(
        string memory name_,
        string memory symbol_,
        address midenOriginToken_,
        uint32 midenNetworkId_,
        address bridgeOwner
    ) ERC20(name_, symbol_) Ownable(bridgeOwner) {
        midenOriginToken = midenOriginToken_;
        midenNetworkId = midenNetworkId_;
    }

    /// Mint on a successful L1 claim. Called by the AggLayer Unified
    /// Bridge contract when it consumes a leaf bridged out of Miden.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// Burn when the token is bridged back to Miden via `bridgeAsset`.
    function burnFrom(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
