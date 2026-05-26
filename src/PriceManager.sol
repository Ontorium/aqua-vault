// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {INAVHook} from "./interfaces/INAVManager.sol";
import {IPriceManager} from "./interfaces/IPriceManager.sol";

import {IVault} from "./interfaces/IVault.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IOffchainNAVStrategy} from "./interfaces/IOffchainNAVStrategy.sol";
import {AccessManaged} from "./AccessManaged.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/// @notice Base share price calculation manager for a single Vault with a dedicated offchain NAV strategy.
/// @dev The Vault remains the source of truth for ERC4626 pricing. This contract only coordinates NAV updates,
/// triggers Vault accrual, and snapshots the resulting share price.
/// @dev NAV updaters are role members in the central RoleManager (per-PriceManager scoped role).
contract PriceManager is IPriceManager, AccessManaged {
    /// @dev Per-PriceManager scoped role name. Combined with address(this) via `_scopedRole(...)`.
    bytes32 internal constant NAV_UPDATER = keccak256("NAV_UPDATER");

    uint256 internal constant WAD = 1e18;

    address public immutable vault;
    address public immutable offchainStrategy;

    Metrics public metrics;

    constructor(IVault vault_, address offchainStrategy_, address _roleManager) AccessManaged(_roleManager) {
        require(address(vault_) != address(0), ErrorsLib.ZeroAddress());
        require(offchainStrategy_ != address(0), ErrorsLib.ZeroAddress());
        require(IOffchainNAVStrategy(offchainStrategy_).vault() == address(vault_), ErrorsLib.InvalidStrategyManager());

        vault = address(vault_);
        offchainStrategy = offchainStrategy_;
    }

    /// @inheritdoc INAVHook
    function onUpdate(uint256 netAssetValue, uint256 availableLiquidity, bytes32 reportHash, string calldata reportURI)
        public
        virtual
    {
        require(
            roleManager.hasRole(_scopedRole(NAV_UPDATER), msg.sender), ErrorsLib.Unauthorized()
        );

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

        emit EventsLib.PriceManagerUpdate(
            vault, offchainStrategy, netAssetValue, totalAssets_, totalSupply_, pricePerShare_
        );
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
