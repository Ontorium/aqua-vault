// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.24;

import {Caps} from "./interfaces/IVault.sol";
import {IGovernanceTimelock} from "./interfaces/IGovernanceTimelock.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IStrategyManager} from "./interfaces/IStrategyManager.sol";
import {IStrategyRegistry} from "./interfaces/IStrategyRegistry.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import "./libraries/ConstantsLib.sol";
import {MathLib} from "./libraries/MathLib.sol";

interface IVaultRolesLike {
    function owner() external view returns (address);
    function isAllocator(address account) external view returns (bool);
}

interface IVaultAllocationLike {
    function allocate(address strategy, bytes memory data, uint256 assets) external;
    function deallocate(address strategy, bytes memory data, uint256 assets) external;
}

/// @notice Holds strategy configuration, caps, allocation accounting, and optional rebalance execution.
/// @dev This contract never holds vault assets. The Vault keeps custody and performs all token transfers.
contract StrategyManager is IStrategyManager {
    using MathLib for uint256;
    using MathLib for int256;

    uint256 internal constant BPS = 10_000;

    address public immutable vault;
    address public immutable asset;

    address public strategyRegistry;

    address[] internal _strategies;
    mapping(address strategy => uint256 indexPlusOne) internal _strategyIndexPlusOne;
    mapping(address strategy => StrategyConfig) public strategyConfig;

    mapping(address strategy => uint256) public strategyAllocation;
    mapping(address strategy => uint256) public forceDeallocatePenalty;

    mapping(bytes32 id => Caps) internal caps;

    modifier onlyGovernance() {
        require(msg.sender == IVaultRolesLike(vault).owner(), ErrorsLib.Unauthorized());
        _;
    }

    modifier onlyGovernanceOrRiskAdmin() {
        address governance = IVaultRolesLike(vault).owner();
        require(
            msg.sender == governance || msg.sender == IGovernanceTimelock(governance).curator()
                || IGovernanceTimelock(governance).isSentinel(msg.sender),
            ErrorsLib.Unauthorized()
        );
        _;
    }

    modifier onlyAllocator() {
        require(IVaultRolesLike(vault).isAllocator(msg.sender), ErrorsLib.Unauthorized());
        _;
    }

    constructor(address _vault, address _asset) {
        require(_vault != address(0), ErrorsLib.ZeroAddress());
        require(_asset != address(0), ErrorsLib.ZeroAddress());

        vault = _vault;
        asset = _asset;
    }

    function strategiesLength() external view returns (uint256) {
        return _strategies.length;
    }

    function strategies(uint256 index) external view returns (address) {
        return _strategies[index];
    }

    function isStrategy(address strategy) public view returns (bool) {
        return _strategyIndexPlusOne[strategy] != 0;
    }

    function isStrategyActive(address strategy) external view returns (bool) {
        return strategyConfig[strategy].active;
    }

    function absoluteCap(bytes32 id) external view returns (uint256) {
        return caps[id].absoluteCap;
    }

    function relativeCap(bytes32 id) external view returns (uint256) {
        return caps[id].relativeCap;
    }

    function allocation(bytes32 id) external view returns (uint256) {
        return caps[id].allocation;
    }

    function setStrategyRegistry(address newStrategyRegistry) external onlyGovernance {
        if (newStrategyRegistry != address(0)) {
            for (uint256 i; i < _strategies.length; ++i) {
                require(
                    IStrategyRegistry(newStrategyRegistry).isInRegistry(_strategies[i]),
                    ErrorsLib.NotInStrategyRegistry()
                );
            }
        }

        strategyRegistry = newStrategyRegistry;
        emit EventsLib.SetStrategyRegistry(newStrategyRegistry);
    }

    function addStrategy(address strategy) external onlyGovernance {
        require(strategy != address(0), ErrorsLib.ZeroAddress());
        require(
            strategyRegistry == address(0) || IStrategyRegistry(strategyRegistry).isInRegistry(strategy),
            ErrorsLib.NotInStrategyRegistry()
        );

        if (!isStrategy(strategy)) {
            _strategies.push(strategy);
            _strategyIndexPlusOne[strategy] = _strategies.length;
            strategyConfig[strategy] = StrategyConfig({
                exists: true,
                active: true,
                capBps: 0,
                targetBps: 0,
                kind: 0
            });
        }

        emit EventsLib.AddStrategy(strategy);
    }

    function removeStrategy(address strategy) external onlyGovernance {
        uint256 indexPlusOne = _strategyIndexPlusOne[strategy];
        require(indexPlusOne != 0, ErrorsLib.NotStrategy());
        require(strategyAllocation[strategy] == 0, ErrorsLib.ZeroAllocation());
        require(IStrategy(strategy).realAssets() == 0, ErrorsLib.ZeroAllocation());

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _strategies.length - 1;

        if (index != lastIndex) {
            address lastStrategy = _strategies[lastIndex];
            _strategies[index] = lastStrategy;
            _strategyIndexPlusOne[lastStrategy] = index + 1;
        }

        _strategies.pop();
        delete _strategyIndexPlusOne[strategy];
        delete strategyConfig[strategy];
        delete forceDeallocatePenalty[strategy];

        emit EventsLib.RemoveStrategy(strategy);
    }

    function setStrategyActive(address strategy, bool active) external onlyGovernance {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());
        strategyConfig[strategy].active = active;
        emit EventsLib.SetStrategyActive(strategy, active);
    }

    function setStrategyCapBps(address strategy, uint256 capBps) external onlyGovernance {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());
        require(capBps <= BPS, ErrorsLib.RelativeCapAboveOne());

        strategyConfig[strategy].capBps = uint16(capBps);
        emit EventsLib.SetStrategyCapBps(strategy, capBps);
    }

    function setStrategyTargetBps(address strategy, uint256 targetBps) external onlyGovernance {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());
        require(targetBps <= BPS, ErrorsLib.RelativeCapAboveOne());

        strategyConfig[strategy].targetBps = uint16(targetBps);
        emit EventsLib.SetStrategyTargetBps(strategy, targetBps);
    }

    function setStrategyKind(address strategy, uint8 kind) external onlyGovernance {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());
        strategyConfig[strategy].kind = kind;
        emit EventsLib.SetStrategyKind(strategy, kind);
    }

    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external onlyGovernance {
        bytes32 id = keccak256(idData);
        require(newAbsoluteCap >= caps[id].absoluteCap, ErrorsLib.AbsoluteCapNotIncreasing());

        caps[id].absoluteCap = newAbsoluteCap.toUint128();
        emit EventsLib.IncreaseAbsoluteCap(id, idData, newAbsoluteCap);
    }

    function decreaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external onlyGovernanceOrRiskAdmin {
        bytes32 id = keccak256(idData);
        require(newAbsoluteCap <= caps[id].absoluteCap, ErrorsLib.AbsoluteCapNotDecreasing());

        caps[id].absoluteCap = uint128(newAbsoluteCap);
        emit EventsLib.DecreaseAbsoluteCap(msg.sender, id, idData, newAbsoluteCap);
    }

    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external onlyGovernance {
        bytes32 id = keccak256(idData);
        require(newRelativeCap <= WAD, ErrorsLib.RelativeCapAboveOne());
        require(newRelativeCap >= caps[id].relativeCap, ErrorsLib.RelativeCapNotIncreasing());

        caps[id].relativeCap = uint128(newRelativeCap);
        emit EventsLib.IncreaseRelativeCap(id, idData, newRelativeCap);
    }

    function decreaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external onlyGovernanceOrRiskAdmin {
        bytes32 id = keccak256(idData);
        require(newRelativeCap <= caps[id].relativeCap, ErrorsLib.RelativeCapNotDecreasing());

        caps[id].relativeCap = uint128(newRelativeCap);
        emit EventsLib.DecreaseRelativeCap(msg.sender, id, idData, newRelativeCap);
    }

    function setForceDeallocatePenalty(address strategy, uint256 newForceDeallocatePenalty) external onlyGovernance {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());
        require(newForceDeallocatePenalty <= MAX_FORCE_DEALLOCATE_PENALTY, ErrorsLib.PenaltyTooHigh());

        forceDeallocatePenalty[strategy] = newForceDeallocatePenalty;
        emit EventsLib.SetForceDeallocatePenalty(strategy, newForceDeallocatePenalty);
    }

    function afterAllocate(address strategy, bytes32[] memory ids, int256 change, uint256 totalAssetsForCaps)
        external
    {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        StrategyConfig memory config = strategyConfig[strategy];
        require(config.exists && config.active, ErrorsLib.NotStrategy());

        _applyStrategyAllocationChange(strategy, change);
        _enforceStrategyCap(strategy, config.capBps, totalAssetsForCaps);

        for (uint256 i; i < ids.length; ++i) {
            Caps storage _caps = caps[ids[i]];
            _caps.allocation = (int256(_caps.allocation) + change).toUint256();

            require(_caps.absoluteCap > 0, ErrorsLib.ZeroAbsoluteCap());
            require(_caps.allocation <= _caps.absoluteCap, ErrorsLib.AbsoluteCapExceeded());
            require(
                _caps.relativeCap == WAD || _caps.allocation <= totalAssetsForCaps.mulDivDown(_caps.relativeCap, WAD),
                ErrorsLib.RelativeCapExceeded()
            );
        }

        emit EventsLib.AfterAllocate(strategy, ids, change, strategyAllocation[strategy]);
    }

    function afterDeallocate(address strategy, bytes32[] memory ids, int256 change) external {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        require(isStrategy(strategy), ErrorsLib.NotStrategy());

        _applyStrategyAllocationChange(strategy, change);

        for (uint256 i; i < ids.length; ++i) {
            Caps storage _caps = caps[ids[i]];
            require(_caps.allocation > 0, ErrorsLib.ZeroAllocation());
            _caps.allocation = (int256(_caps.allocation) + change).toUint256();
        }

        emit EventsLib.AfterDeallocate(strategy, ids, change, strategyAllocation[strategy]);
    }

    function rebalance(RebalanceAction[] calldata actions) external onlyAllocator {
        // The StrategyManager must be whitelisted as allocator in the Vault for these calls to succeed.
        for (uint256 i; i < actions.length; ++i) {
            if (actions[i].isAllocate) {
                IVaultAllocationLike(vault).allocate(actions[i].strategy, actions[i].data, actions[i].assets);
            } else {
                IVaultAllocationLike(vault).deallocate(actions[i].strategy, actions[i].data, actions[i].assets);
            }
        }

        emit EventsLib.Rebalance(msg.sender, actions.length);
    }

    function totalStrategyAssets() external view returns (uint256 totalAssets) {
        for (uint256 i; i < _strategies.length; ++i) {
            totalAssets += IStrategy(_strategies[i]).totalAssets();
        }
    }

    function availableStrategyLiquidity() external view returns (uint256 liquidity) {
        bytes4 selector = bytes4(keccak256("availableLiquidity()"));

        for (uint256 i; i < _strategies.length; ++i) {
            (bool success, bytes memory data) = _strategies[i].staticcall(abi.encodeWithSelector(selector));
            if (success && data.length >= 32) liquidity += abi.decode(data, (uint256));
        }
    }

    function _applyStrategyAllocationChange(address strategy, int256 change) internal {
        if (change == 0) return;

        strategyAllocation[strategy] = (int256(strategyAllocation[strategy]) + change).toUint256();
    }

    function _enforceStrategyCap(address strategy, uint256 capBps, uint256 totalAssetsForCaps) internal view {
        require(capBps > 0, ErrorsLib.ZeroAbsoluteCap());
        require(strategyAllocation[strategy] <= totalAssetsForCaps.mulDivDown(capBps, BPS), ErrorsLib.RelativeCapExceeded());
    }
}
