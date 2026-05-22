// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {Caps} from "./IVault.sol";

interface IStrategyManager {
    struct StrategyConfig {
        bool exists;
        bool active;
        uint16 capBps;
        uint16 targetBps;
        uint8 kind; // 0 = onchain, 1 = offchain reported, custom values are allowed.
    }

    struct RebalanceAction {
        address strategy;
        bytes data;
        uint256 assets;
        bool isAllocate;
    }

    function vault() external view returns (address);
    function asset() external view returns (address);

    function setStrategyRegistry(address newStrategyRegistry) external;

    function addStrategy(address strategy) external;
    function removeStrategy(address strategy) external;
    function setStrategyActive(address strategy, bool active) external;
    function setStrategyCapBps(address strategy, uint256 capBps) external;
    function setStrategyTargetBps(address strategy, uint256 targetBps) external;
    function setStrategyKind(address strategy, uint8 kind) external;

    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function decreaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function decreaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function setForceDeallocatePenalty(address strategy, uint256 newForceDeallocatePenalty) external;

    function afterAllocate(address strategy, bytes32[] memory ids, int256 change, uint256 totalAssetsForCaps) external;
    function afterDeallocate(address strategy, bytes32[] memory ids, int256 change) external;

    function rebalance(RebalanceAction[] calldata actions) external;

    function strategiesLength() external view returns (uint256);
    function strategies(uint256 index) external view returns (address);
    function isStrategy(address strategy) external view returns (bool);
    function isStrategyActive(address strategy) external view returns (bool);

    function strategyRegistry() external view returns (address);
    function strategyAllocation(address strategy) external view returns (uint256);
    function forceDeallocatePenalty(address strategy) external view returns (uint256);

    function absoluteCap(bytes32 id) external view returns (uint256);
    function relativeCap(bytes32 id) external view returns (uint256);
    function allocation(bytes32 id) external view returns (uint256);

    function totalStrategyAssets() external view returns (uint256);
    function availableStrategyLiquidity() external view returns (uint256);
}
