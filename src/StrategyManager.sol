// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.24;

import {Caps} from "./interfaces/IVault.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IStrategyManager} from "./interfaces/IStrategyManager.sol";
import {IStrategyRegistry} from "./interfaces/IStrategyRegistry.sol";
import {IVault} from "./interfaces/IVault.sol";
import {AccessManaged} from "./AccessManaged.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import "./libraries/ConstantsLib.sol";
import {MathLib} from "./libraries/MathLib.sol";

/// @notice Stores strategy configuration and cap accounting for a vault.
/// @dev Asset custody remains in the vault.
contract StrategyManager is IStrategyManager, AccessManaged {
    using MathLib for uint256;
    using MathLib for int256;

    uint256 internal constant BPS = 10_000;

    uint8 public constant STRATEGY_KIND_NONE = 0;
    uint8 public constant STRATEGY_KIND_ONCHAIN = 1;
    uint8 public constant STRATEGY_KIND_OFFCHAIN_NAV = 2;

    address public immutable vault;
    address public immutable asset;

    address public strategyRegistry;

    address[] internal _strategies;
    mapping(address strategy => uint256 indexPlusOne) internal _strategyIndexPlusOne;
    mapping(address strategy => StrategyConfig) public strategyConfig;

    mapping(bytes32 id => Caps) internal caps;

    modifier onlyVault() {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        _;
    }

    constructor(address _vault, address _asset, address _roleManager) AccessManaged(_roleManager, _vault) {
        require(_asset != address(0), ErrorsLib.ZeroAddress());

        vault = _vault;
        asset = _asset;
    }

    /* GETTERS */

    function strategiesLength() external view returns (uint256) {
        return _strategies.length;
    }

    function strategies(uint256 index) external view returns (address) {
        return _strategies[index];
    }

    function allStrategies() external view returns (address[] memory) {
        return _strategies;
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

    /// @notice Returns the assets currently reported by `strategy`.
    function strategyAllocation(address strategy) public view returns (uint256) {
        if (!isStrategy(strategy)) return 0;
        return IStrategy(strategy).totalAssets();
    }

    function strategyInfo(address strategy) external view returns (StrategyInfo memory info) {
        StrategyConfig memory config = strategyConfig[strategy];

        info.strategy = strategy;
        info.exists = config.exists;
        info.active = config.active;
        info.kind = config.kind;
        info.capBps = config.capBps;
        info.targetBps = config.targetBps;

        if (config.exists) {
            info.totalAssets = IStrategy(strategy).totalAssets();
            info.availableLiquidity = _availableLiquidityOf(strategy);
        }
    }

    function allStrategyInfo() external view returns (StrategyInfo[] memory infos) {
        uint256 length = _strategies.length;
        infos = new StrategyInfo[](length);

        for (uint256 i; i < length;) {
            address strategy = _strategies[i];
            StrategyConfig memory config = strategyConfig[strategy];

            infos[i] = StrategyInfo({
                strategy: strategy,
                exists: config.exists,
                active: config.active,
                kind: config.kind,
                capBps: config.capBps,
                targetBps: config.targetBps,
                totalAssets: IStrategy(strategy).totalAssets(),
                availableLiquidity: _availableLiquidityOf(strategy)
            });
            unchecked {
                ++i;
            }
        }
    }

    /* GOVERNANCE FUNCTIONS */

    function setStrategyRegistry(address newStrategyRegistry) external onlyRole(GOVERNANCE_ROLE) {
        if (newStrategyRegistry != address(0)) {
            uint256 len = _strategies.length;
            for (uint256 i; i < len;) {
                require(
                    IStrategyRegistry(newStrategyRegistry).isInRegistry(_strategies[i]),
                    ErrorsLib.NotInStrategyRegistry()
                );
                unchecked {
                    ++i;
                }
            }
        }

        strategyRegistry = newStrategyRegistry;
        emit EventsLib.SetStrategyRegistry(newStrategyRegistry);
    }

    function addStrategy(address strategy, uint8 kind, uint256 capBps, uint256 targetBps)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        _addStrategy(strategy, kind, capBps, targetBps);
    }

    function removeStrategy(address strategy) external onlyRole(GOVERNANCE_ROLE) {
        uint256 indexPlusOne = _strategyIndexPlusOne[strategy];
        require(indexPlusOne != 0, ErrorsLib.NotStrategy());

        // A strategy must be empty before removal.
        require(strategyAllocation(strategy) == 0, ErrorsLib.ZeroAllocation());
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

        emit EventsLib.RemoveStrategy(strategy);
    }

    function setStrategyActive(address strategy, bool active) external onlyRole(GOVERNANCE_ROLE) {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());

        strategyConfig[strategy].active = active;
        emit EventsLib.SetStrategyActive(strategy, active);
    }

    function setStrategyCapBps(address strategy, uint256 capBps) external onlyRole(GOVERNANCE_ROLE) {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());
        require(capBps <= BPS, ErrorsLib.RelativeCapAboveOne());

        strategyConfig[strategy].capBps = uint16(capBps);
        emit EventsLib.SetStrategyCapBps(strategy, capBps);
    }

    function setStrategyTargetBps(address strategy, uint256 targetBps) external onlyRole(GOVERNANCE_ROLE) {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());
        require(targetBps <= BPS, ErrorsLib.RelativeCapAboveOne());

        strategyConfig[strategy].targetBps = uint16(targetBps);
        emit EventsLib.SetStrategyTargetBps(strategy, targetBps);
    }

    function setStrategyKind(address strategy, uint8 kind) external onlyRole(GOVERNANCE_ROLE) {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());

        strategyConfig[strategy].kind = kind;
        emit EventsLib.SetStrategyKind(strategy, kind);
    }

    function increaseAbsoluteCap(bytes calldata idData, uint256 newAbsoluteCap) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 id = keccak256(idData);
        require(newAbsoluteCap >= caps[id].absoluteCap, ErrorsLib.AbsoluteCapNotIncreasing());

        caps[id].absoluteCap = newAbsoluteCap.toUint128();
        emit EventsLib.IncreaseAbsoluteCap(id, idData, newAbsoluteCap);
    }

    function decreaseAbsoluteCap(bytes calldata idData, uint256 newAbsoluteCap) external {
        _requireAnyRole(GOVERNANCE_ROLE, CURATOR_ROLE, SENTINEL_ROLE);
        bytes32 id = keccak256(idData);
        require(newAbsoluteCap <= caps[id].absoluteCap, ErrorsLib.AbsoluteCapNotDecreasing());

        caps[id].absoluteCap = uint128(newAbsoluteCap);
        emit EventsLib.DecreaseAbsoluteCap(msg.sender, id, idData, newAbsoluteCap);
    }

    function increaseRelativeCap(bytes calldata idData, uint256 newRelativeCap) external onlyRole(GOVERNANCE_ROLE) {
        bytes32 id = keccak256(idData);
        require(newRelativeCap <= WAD, ErrorsLib.RelativeCapAboveOne());
        require(newRelativeCap >= caps[id].relativeCap, ErrorsLib.RelativeCapNotIncreasing());

        caps[id].relativeCap = uint128(newRelativeCap);
        emit EventsLib.IncreaseRelativeCap(id, idData, newRelativeCap);
    }

    function decreaseRelativeCap(bytes calldata idData, uint256 newRelativeCap) external {
        _requireAnyRole(GOVERNANCE_ROLE, CURATOR_ROLE, SENTINEL_ROLE);
        bytes32 id = keccak256(idData);
        require(newRelativeCap <= caps[id].relativeCap, ErrorsLib.RelativeCapNotDecreasing());

        caps[id].relativeCap = uint128(newRelativeCap);
        emit EventsLib.DecreaseRelativeCap(msg.sender, id, idData, newRelativeCap);
    }

    function setForceDeallocatePenalty(address strategy, uint256 newForceDeallocatePenalty)
        external
        onlyRole(GOVERNANCE_ROLE)
    {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());
        require(newForceDeallocatePenalty <= MAX_FORCE_DEALLOCATE_PENALTY, ErrorsLib.PenaltyTooHigh());

        strategyConfig[strategy].forceDeallocatePenalty = uint64(newForceDeallocatePenalty);
        emit EventsLib.SetForceDeallocatePenalty(strategy, newForceDeallocatePenalty);
    }

    function forceDeallocatePenalty(address strategy) external view returns (uint256) {
        return strategyConfig[strategy].forceDeallocatePenalty;
    }

    /* VAULT HOOKS */

    /// @notice Updates cap accounting after a vault allocation.
    function onAllocate(address strategy, bytes32[] calldata ids, int256 change, uint256 totalAssetsForCaps)
        external
        onlyVault
    {
        StrategyConfig memory config = strategyConfig[strategy];
        require(config.exists && config.active, ErrorsLib.NotStrategy());

        uint256 len = ids.length;
        for (uint256 i; i < len;) {
            Caps storage _caps = caps[ids[i]];
            _caps.allocation = (int256(_caps.allocation) + change).toUint256();

            require(_caps.absoluteCap > 0, ErrorsLib.ZeroAbsoluteCap());
            require(_caps.allocation <= _caps.absoluteCap, ErrorsLib.AbsoluteCapExceeded());
            require(
                _caps.relativeCap == WAD || _caps.allocation <= totalAssetsForCaps.mulDivDown(_caps.relativeCap, WAD),
                ErrorsLib.RelativeCapExceeded()
            );
            unchecked {
                ++i;
            }
        }

        _enforceStrategyCap(strategy, config.capBps, totalAssetsForCaps);

        emit EventsLib.AfterAllocate(strategy, ids, change, strategyAllocation(strategy));
    }

    /// @notice Updates cap accounting after a vault deallocation.
    /// @dev Does not enforce `active` so inactive strategies can still unwind.
    function onDeallocate(address strategy, bytes32[] calldata ids, int256 change) external onlyVault {
        require(isStrategy(strategy), ErrorsLib.NotStrategy());

        uint256 len = ids.length;
        for (uint256 i; i < len;) {
            Caps storage _caps = caps[ids[i]];
            require(_caps.allocation > 0, ErrorsLib.ZeroAllocation());
            _caps.allocation = (int256(_caps.allocation) + change).toUint256();
            unchecked {
                ++i;
            }
        }

        emit EventsLib.AfterDeallocate(strategy, ids, change, strategyAllocation(strategy));
    }

    /* ALLOCATION HELPERS */

    /// @notice Optional helper that relays allocate and deallocate calls to the vault.
    /// @dev This contract must hold the required allocator roles for the relayed calls.
    function rebalance(RebalanceAction[] calldata actions) external {
        _requireAnyRole(GOVERNANCE_ROLE, CURATOR_ROLE, SENTINEL_ROLE);
        uint256 len = actions.length;
        for (uint256 i; i < len;) {
            RebalanceAction calldata action = actions[i];
            if (action.isAllocate) {
                IVault(vault).allocate(action.strategy, action.data, action.assets);
            } else {
                IVault(vault).deallocate(action.strategy, action.data, action.assets);
            }
            unchecked {
                ++i;
            }
        }

        emit EventsLib.Rebalance(msg.sender, len);
    }

    /* AGGREGATE VIEWS */

    function totalStrategyAssets() external view returns (uint256 totalAssets) {
        uint256 len = _strategies.length;
        for (uint256 i; i < len;) {
            totalAssets += IStrategy(_strategies[i]).totalAssets();
            unchecked {
                ++i;
            }
        }
    }

    function availableStrategyLiquidity() external view returns (uint256 liquidity) {
        uint256 len = _strategies.length;
        for (uint256 i; i < len;) {
            liquidity += _availableLiquidityOf(_strategies[i]);
            unchecked {
                ++i;
            }
        }
    }

    function totalOnchainStrategyAssets() external view returns (uint256 totalAssets) {
        uint256 len = _strategies.length;
        for (uint256 i; i < len;) {
            address strategy = _strategies[i];
            if (strategyConfig[strategy].kind == STRATEGY_KIND_ONCHAIN) {
                totalAssets += IStrategy(strategy).totalAssets();
            }
            unchecked {
                ++i;
            }
        }
    }

    function availableOnchainStrategyLiquidity() external view returns (uint256 liquidity) {
        uint256 len = _strategies.length;
        for (uint256 i; i < len;) {
            address strategy = _strategies[i];
            if (strategyConfig[strategy].kind == STRATEGY_KIND_ONCHAIN) {
                liquidity += _availableLiquidityOf(strategy);
            }
            unchecked {
                ++i;
            }
        }
    }

    function totalOffchainStrategyAssets() external view returns (uint256 totalAssets) {
        uint256 len = _strategies.length;
        for (uint256 i; i < len;) {
            address strategy = _strategies[i];
            if (strategyConfig[strategy].kind == STRATEGY_KIND_OFFCHAIN_NAV) {
                totalAssets += IStrategy(strategy).totalAssets();
            }
            unchecked {
                ++i;
            }
        }
    }

    function availableOffchainStrategyLiquidity() external view returns (uint256 liquidity) {
        uint256 len = _strategies.length;
        for (uint256 i; i < len;) {
            address strategy = _strategies[i];
            if (strategyConfig[strategy].kind == STRATEGY_KIND_OFFCHAIN_NAV) {
                liquidity += _availableLiquidityOf(strategy);
            }
            unchecked {
                ++i;
            }
        }
    }

    /* INTERNAL FUNCTIONS */

    function _addStrategy(address strategy, uint8 kind, uint256 capBps, uint256 targetBps) internal {
        require(strategy != address(0), ErrorsLib.ZeroAddress());
        require(capBps <= BPS, ErrorsLib.RelativeCapAboveOne());
        require(targetBps <= BPS, ErrorsLib.RelativeCapAboveOne());
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
                capBps: uint16(capBps),
                targetBps: uint16(targetBps),
                kind: kind,
                forceDeallocatePenalty: 0
            });

            emit EventsLib.AddStrategy(strategy);
            emit EventsLib.SetStrategyKind(strategy, kind);
            emit EventsLib.SetStrategyCapBps(strategy, capBps);
            emit EventsLib.SetStrategyTargetBps(strategy, targetBps);
        }
    }

    function _availableLiquidityOf(address strategy) internal view returns (uint256 liquidity) {
        bytes4 selector = bytes4(keccak256("availableLiquidity()"));
        (bool success, bytes memory data) = strategy.staticcall(abi.encodeWithSelector(selector));
        if (success && data.length >= 32) {
            liquidity = abi.decode(data, (uint256));
        }
    }

    function _enforceStrategyCap(address strategy, uint256 capBps, uint256 totalAssetsForCaps) internal view {
        if (capBps == 0) return;

        require(
            strategyAllocation(strategy) <= totalAssetsForCaps.mulDivDown(capBps, BPS), ErrorsLib.RelativeCapExceeded()
        );
    }
}
