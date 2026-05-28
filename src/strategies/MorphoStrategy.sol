// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IMorpho, MarketParams} from "./interfaces/IMorpho.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";


contract MorphoStrategy is IStrategy {
    address public immutable vault;
    address public immutable asset;
    address public immutable morpho;

    bytes32[] internal _marketIds;
    mapping(bytes32 marketId => uint256) public supplyShares;
    mapping(bytes32 marketId => uint256) internal _marketIndexPlusOne;

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
        morpho = _morpho;

        SafeERC20Lib.safeApprove(_asset, _morpho, type(uint256).max);
    }

    function marketIdsLength() external view returns (uint256) {
        return _marketIds.length;
    }

    function marketIds(uint256 index) external view returns (bytes32) {
        return _marketIds[index];
    }

    function allocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        require(marketParams.loanToken == asset, ErrorsLib.InvalidRequest());

        bytes32 marketId = _marketId(marketParams);
        uint256 oldAssets = _expectedSupplyAssets(marketId);

        if (assets > 0) {
            (, uint256 mintedShares) = IMorpho(morpho).supply(marketParams, assets, 0, address(this), hex"");
            supplyShares[marketId] += mintedShares;
        }

        uint256 newAssets = _expectedSupplyAssets(marketId);
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
        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        require(marketParams.loanToken == asset, ErrorsLib.InvalidRequest());

        bytes32 marketId = _marketId(marketParams);
        uint256 oldAssets = _expectedSupplyAssets(marketId);

        if (assets > 0) {
            (, uint256 burnedShares) =
                IMorpho(morpho).withdraw(marketParams, assets, 0, address(this), address(this));
            supplyShares[marketId] -= burnedShares;
        }

        uint256 newAssets = _expectedSupplyAssets(marketId);
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
            total += _expectedSupplyAssets(_marketIds[i]);
            unchecked { ++i; }
        }
    }

    function availableLiquidity() external view returns (uint256 liquidity) {
        uint256 len = _marketIds.length;
        for (uint256 i; i < len;) {
            bytes32 marketId = _marketIds[i];
            uint256 assetsOnMarket = _expectedSupplyAssets(marketId);
            uint256 marketLiquidity = _marketLiquidity(marketId);
            liquidity += marketLiquidity < assetsOnMarket ? marketLiquidity : assetsOnMarket;
            unchecked { ++i; }
        }
    }

    function _expectedSupplyAssets(bytes32 marketId) internal view returns (uint256) {
        uint256 shares = supplyShares[marketId];
        if (shares == 0) return 0;

        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = IMorpho(morpho).market(marketId);
        if (totalSupplyShares == 0) return 0;

        return shares * uint256(totalSupplyAssets) / uint256(totalSupplyShares);
    }

    function _marketLiquidity(bytes32 marketId) internal view returns (uint256) {
        (uint128 totalSupplyAssets,, uint128 totalBorrowAssets,,,) = IMorpho(morpho).market(marketId);
        if (totalSupplyAssets <= totalBorrowAssets) return 0;
        return uint256(totalSupplyAssets - totalBorrowAssets);
    }

    function _marketId(MarketParams memory marketParams) internal pure returns (bytes32) {
        return keccak256(abi.encode(marketParams));
    }

    function _syncMarketList(bytes32 marketId, uint256 oldAssets, uint256 newAssets) internal {
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
                bytes32 lastMarketId = _marketIds[lastIndex];
                _marketIds[index] = lastMarketId;
                _marketIndexPlusOne[lastMarketId] = index + 1;
            }

            _marketIds.pop();
            delete _marketIndexPlusOne[marketId];
        }
    }
}
