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

    struct StrategyInfo {
        address strategy;
        bool exists;
        bool active;
        uint8 kind;
        uint256 capBps;
        uint256 targetBps;
        uint256 totalAssets;
        uint256 availableLiquidity;
    }

    struct RebalanceAction {
        address strategy;
        bool isAllocate;
        uint256 assets;
        bytes data;
    }

    function vault() external view returns (address);
    function asset() external view returns (address);

    function setStrategyRegistry(address newStrategyRegistry) external;

    function addStrategy(address strategy, uint8 kind, uint256 capBps, uint256 targetBps) external;
    function removeStrategy(address strategy) external;
    function setStrategyActive(address strategy, bool active) external;
    function setStrategyCapBps(address strategy, uint256 capBps) external;
    function setStrategyTargetBps(address strategy, uint256 targetBps) external;
    function setStrategyKind(address strategy, uint8 kind) external;

    function increaseAbsoluteCap(bytes calldata idData, uint256 newAbsoluteCap) external;
    function decreaseAbsoluteCap(bytes calldata idData, uint256 newAbsoluteCap) external;
    function increaseRelativeCap(bytes calldata idData, uint256 newRelativeCap) external;
    function decreaseRelativeCap(bytes calldata idData, uint256 newRelativeCap) external;
    function setForceDeallocatePenalty(address strategy, uint256 newForceDeallocatePenalty) external;

    /// @notice Vault-only cap accounting hooks invoked after each allocate/deallocate.
    function onAllocate(address strategy, bytes32[] calldata ids, int256 change, uint256 totalAssetsForCaps) external;
    function onDeallocate(address strategy, bytes32[] calldata ids, int256 change) external;

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
