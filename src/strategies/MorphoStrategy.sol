// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IStrategy} from "../interfaces/IStrategy.sol";
// Morpho Blue periphery is vendored under ./morpho to avoid an external git submodule. The folder
// preserves the upstream layout so the vendored files' internal relative imports keep working.
import {IMorpho, MarketParams, Id} from "./morpho/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "./morpho/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoLib} from "./morpho/libraries/periphery/MorphoLib.sol";
import {MarketParamsLib} from "./morpho/libraries/MarketParamsLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

/// @notice Morpho Blue supply strategy. Each market the strategy supplies into is tracked by `Id` along
/// with the `MarketParams` needed to compute interest-accrued balances off-chain.
/// @dev Reads via `morpho.market(id)` are stale (they exclude interest since `lastUpdate`). All view paths
/// here use `MorphoBalancesLib.expectedMarketBalances` / `expectedSupplyAssets`, which project the
/// state forward as if `accrueInterest` had run — so `totalAssets()` reports the real, fresh value.
/// Mutating paths (allocate/deallocate) additionally call `morpho.accrueInterest(mp)` first so Morpho's
/// on-chain state matches what we just read.
contract MorphoStrategy is IStrategy {
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    address public immutable vault;
    address public immutable asset;
    IMorpho public immutable morpho;

    Id[] internal _marketIds;
    mapping(Id marketId => uint256) internal _marketIndexPlusOne;
    /// @dev Stored `MarketParams` per registered market. Required to query `MorphoBalancesLib` in views.
    mapping(Id marketId => MarketParams) internal _marketParams;

    modifier onlyVault() {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        _;
    }

    constructor(address _vault, address _asset, address _morpho) {
        require(_vault != address(0), ErrorsLib.ZeroAddress());
        require(_asset != address(0), ErrorsLib.ZeroAddress());
        require(_morpho != address(0), ErrorsLib.ZeroAddress());

        vault = _vault;
        asset = _asset;
        morpho = IMorpho(_morpho);

        SafeERC20Lib.safeApprove(_asset, _morpho, type(uint256).max);
    }

    function marketIdsLength() external view returns (uint256) {
        return _marketIds.length;
    }

    function marketIds(uint256 index) external view returns (Id) {
        return _marketIds[index];
    }

    function marketParams(Id marketId) external view returns (MarketParams memory) {
        return _marketParams[marketId];
    }

    /// @dev Single source of truth: read this strategy's supply shares directly from Morpho's storage
    /// instead of mirroring them in our own mapping. Same value, no drift.
    function supplyShares(Id id) external view returns (uint256) {
        return morpho.supplyShares(id, address(this));
    }

    function allocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        MarketParams memory mp = abi.decode(data, (MarketParams));
        require(mp.loanToken == asset, ErrorsLib.InvalidRequest());

        // Settle Morpho's state so subsequent `market(id)`/balances reads agree with our view paths.
        morpho.accrueInterest(mp);

        Id marketId = mp.id();
        uint256 oldAssets = _expectedSupplyAssets(mp);

        if (assets > 0) {
            morpho.supply(mp, assets, 0, address(this), hex"");
            // First time we see this market: snapshot its params so views can query MorphoBalancesLib.
            if (_marketParams[marketId].loanToken == address(0)) _marketParams[marketId] = mp;
        }

        uint256 newAssets = _expectedSupplyAssets(mp);
        _syncMarketList(marketId, oldAssets, newAssets);

        ids = new bytes32[](1);
        ids[0] = keccak256(abi.encode(address(this), marketId));
        change = int256(newAssets) - int256(oldAssets);
    }

    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        MarketParams memory mp = abi.decode(data, (MarketParams));
        require(mp.loanToken == asset, ErrorsLib.InvalidRequest());

        morpho.accrueInterest(mp);

        Id marketId = mp.id();
        uint256 oldAssets = _expectedSupplyAssets(mp);

        if (assets > 0) morpho.withdraw(mp, assets, 0, address(this), address(this));

        uint256 newAssets = _expectedSupplyAssets(mp);
        _syncMarketList(marketId, oldAssets, newAssets);

        ids = new bytes32[](1);
        ids[0] = keccak256(abi.encode(address(this), marketId));
        change = int256(newAssets) - int256(oldAssets);
    }

    function realAssets() external view returns (uint256) {
        return totalAssets();
    }

    function totalAssets() public view returns (uint256 total) {
        uint256 len = _marketIds.length;
        for (uint256 i; i < len;) {
            total += _expectedSupplyAssets(_marketParams[_marketIds[i]]);
            unchecked { ++i; }
        }
    }

    function availableLiquidity() external view returns (uint256 liquidity) {
        uint256 len = _marketIds.length;
        for (uint256 i; i < len;) {
            MarketParams memory mp = _marketParams[_marketIds[i]];
            (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(mp);

            uint256 onMarket = _expectedSupplyAssets(mp);
            uint256 free = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
            liquidity += free < onMarket ? free : onMarket;
            unchecked { ++i; }
        }
    }

    /// @dev Returns this strategy's projected supply assets on a market, including pending interest.
    /// Equivalent to calling `accrueInterest(mp)` and reading `market(id)`, but view-only.
    function _expectedSupplyAssets(MarketParams memory mp) internal view returns (uint256) {
        return morpho.expectedSupplyAssets(mp, address(this));
    }

    function _syncMarketList(Id marketId, uint256 oldAssets, uint256 newAssets) internal {
        uint256 indexPlusOne = _marketIndexPlusOne[marketId];
        if (oldAssets == 0 && newAssets > 0 && indexPlusOne == 0) {
            _marketIds.push(marketId);
            _marketIndexPlusOne[marketId] = _marketIds.length;
            return;
        }

        if (oldAssets > 0 && newAssets == 0 && indexPlusOne != 0) {
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = _marketIds.length - 1;

            if (index != lastIndex) {
                Id lastMarketId = _marketIds[lastIndex];
                _marketIds[index] = lastMarketId;
                _marketIndexPlusOne[lastMarketId] = index + 1;
            }

            _marketIds.pop();
            delete _marketIndexPlusOne[marketId];
            // Keep `_marketParams[marketId]` so a re-entry can reuse the snapshot; cheap & harmless.
        }
    }
}
