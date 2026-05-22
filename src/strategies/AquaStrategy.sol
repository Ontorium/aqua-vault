// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IAaveV2, IAaveV2AToken} from "./interfaces/IAaveV2.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

contract AquaStrategy is IStrategy {
    address public immutable vault;
    address public immutable asset;
    address public immutable lendingPool;
    address public immutable aToken;

    modifier onlyVault() {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        _;
    }

    constructor(address _vault, address _asset, address _lendingPool, address _aToken) {
        require(_vault != address(0), ErrorsLib.ZeroAddress());
        require(_asset != address(0), ErrorsLib.ZeroAddress());
        require(_lendingPool != address(0), ErrorsLib.ZeroAddress());
        require(_aToken != address(0), ErrorsLib.ZeroAddress());

        vault = _vault;
        asset = _asset;
        lendingPool = _lendingPool;
        aToken = _aToken;

        SafeERC20Lib.safeApprove(_asset, _lendingPool, type(uint256).max);
    }

    function allocate(bytes memory, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        if (assets > 0) IAaveV2(lendingPool).deposit(asset, assets, address(this), 0);

        ids = new bytes32[](1);
        ids[0] = keccak256(abi.encode(address(this), aToken));
        change = int256(assets);
    }

    function deallocate(bytes memory, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        if (assets > 0) {
            uint256 withdrawn = IAaveV2(lendingPool).withdraw(asset, assets, address(this));
            require(withdrawn == assets, ErrorsLib.InsufficientLiquidity());
        }

        ids = new bytes32[](1);
        ids[0] = keccak256(abi.encode(address(this), aToken));
        change = -int256(assets);
    }

    function realAssets() external view returns (uint256) {
        return totalAssets();
    }

    function totalAssets() public view returns (uint256) {
        return IAaveV2AToken(aToken).balanceOf(address(this));
    }

    function availableLiquidity() external view returns (uint256) {
        uint256 total = totalAssets();
        uint256 liquidity = IERC20(asset).balanceOf(aToken);
        return liquidity < total ? liquidity : total;
    }
}
