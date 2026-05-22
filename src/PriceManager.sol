// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {INAVHook} from "./interfaces/INAVManager.sol";
import {IPriceManager} from "./interfaces/IPriceManager.sol";

import {IVault} from "./interfaces/IVault.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IOffchainNAVStrategy} from "./interfaces/IOffchainNAVStrategy.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @notice Base share price calculation manager for a single Vault with a dedicated offchain NAV strategy.
/// @dev The Vault remains the source of truth for ERC4626 pricing. This contract only coordinates NAV updates,
/// triggers Vault accrual, and snapshots the resulting share price.
contract PriceManager is IPriceManager {
    uint256 internal constant WAD = 1e18;

    address public immutable vault;
    address public immutable navUpdater;
    address public immutable offchainStrategy;

    Metrics public metrics;

    event Update(
        address indexed vault,
        address indexed offchainStrategy,
        uint256 netAssetValue,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 pricePerShare
    );

    constructor(IVault vault_, address offchainStrategy_, address navUpdater_) {
        require(address(vault_) != address(0), ErrorsLib.ZeroAddress());
        require(offchainStrategy_ != address(0), ErrorsLib.ZeroAddress());
        require(navUpdater_ != address(0), ErrorsLib.ZeroAddress());
        require(IOffchainNAVStrategy(offchainStrategy_).vault() == address(vault_), ErrorsLib.InvalidStrategyManager());

        vault = address(vault_);
        offchainStrategy = offchainStrategy_;
        navUpdater = navUpdater_;
    }

    // Updates

    /// @inheritdoc INAVHook
    function onUpdate(uint256 netAssetValue, uint256 availableLiquidity, bytes32 reportHash, string calldata reportURI)
        public
        virtual
    {
        require(msg.sender == navUpdater, ErrorsLib.Unauthorized());

        IOffchainNAVStrategy(offchainStrategy).report(netAssetValue, availableLiquidity, reportHash, reportURI);
        IVault(vault).syncReportedNAV();

        uint256 totalAssets_ = IVault(vault).totalAssets();
        uint256 totalSupply_ = IERC20(vault).totalSupply();
        uint256 pricePerShare_ = _pricePerShare(totalAssets_, totalSupply_);

        metrics = Metrics({
            netAssetValue: _toUint128(netAssetValue),
            totalAssets: _toUint128(totalAssets_),
            totalSupply: _toUint128(totalSupply_),
            lastUpdate: uint64(block.timestamp),
            pricePerShare: pricePerShare_
        });

        emit Update(vault, offchainStrategy, netAssetValue, totalAssets_, totalSupply_, pricePerShare_);
    }

    // Helpers
    function pricePerShare() public view returns (uint256) {
        return metrics.pricePerShare;
    }

    function previewPricePerShare() external view returns (uint256) {
        uint256 totalAssets_ = IVault(vault).totalAssets();
        uint256 totalSupply_ = IERC20(vault).totalSupply();
        return _pricePerShare(totalAssets_, totalSupply_);
    }

    function _pricePerShare(uint256 totalAssets_, uint256 totalSupply_) internal pure returns (uint256) {
        return totalSupply_ == 0 ? WAD : totalAssets_ * WAD / totalSupply_;
    }

    function _toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert ErrorsLib.CastOverflow();
        return uint128(value);
    }
}
