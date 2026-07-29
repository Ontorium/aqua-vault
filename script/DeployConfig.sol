// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {Script} from "../lib/forge-std/src/Script.sol";
import {stdJson} from "../lib/forge-std/src/StdJson.sol";

/// @notice Loads per-network deploy configuration from a JSON file under ./config, selected by
/// `block.chainid` (Aave-style). All tunables (roles, fees, timelock delays, offchain, caps, strategy
/// settings, morpho market) live in the JSON so the same scripts deploy to any network by pointing at a
/// different file.
///
/// Resolution order:
///   1. CONFIG_FILE env var (explicit path, e.g. for anvil/local) — wins if set.
///   2. block.chainid -> config/<network>.json  (421614 = arbitrum_sepolia, 42161 = arbitrum).
///
/// **Missing keys fall back to the DEFAULT_* constants below** (the values the scripts previously
/// hardcoded), so a config can be filled in incrementally and an empty file reproduces old behavior.
abstract contract DeployConfig is Script {
    using stdJson for string;

    /* ── DEFAULTS (current hardcoded behavior) ── */
    uint256 internal constant DEFAULT_MAX_RATE = uint256(1e18) / uint256(365 days); // ~100% APR (script 11)
    uint256 internal constant DEFAULT_STALE_PERIOD = 1 days; // script 12
    uint256 internal constant DEFAULT_MAX_CHANGE_BPS = 1000; // 10% (script 12)
    uint256 internal constant DEFAULT_CAP_ABS = type(uint128).max; // uncapped (scripts 09/12/13)
    uint256 internal constant DEFAULT_CAP_REL = 1e18; // WAD = 100%
    uint256 internal constant DEFAULT_LLTV = 0.86e18; // demo market
    // Timelock: script 08 "test" preset default (seconds). Set mainnet values in the JSON for production.
    uint256 internal constant DEFAULT_TL_HIGH = 60;
    uint256 internal constant DEFAULT_TL_MEDIUM = 60;
    uint256 internal constant DEFAULT_TL_LOW = 0;

    struct Config {
        /* 1. roles (deployer/owner+governance come from signer/Timelock, not here) */
        address curator;
        address sentinel;
        address allocator;
        address offchainManager;
        address offchainReporter;
        /* 2. fee values (WAD-scaled; management/maxRate are per-second) */
        uint256 depositFee;
        uint256 withdrawalFee;
        uint256 performanceFee;
        uint256 managementFee;
        uint256 maxRate;
        uint256 forceDeallocatePenalty;
        /* 3. fee recipients */
        address protocolFeeRecipient;
        address performanceFeeRecipient;
        address managementFeeRecipient;
        /* 4. timelock delays (seconds) */
        uint256 timelockHigh;
        uint256 timelockMedium;
        uint256 timelockLow;
        /* 5. offchain strategy */
        uint256 stalePeriod;
        uint256 maxChangeBps;
        address custodian;
        /* 6. per-strategy caps (absolute in asset units, relative in WAD) */
        uint256 aquaStrategyAbsCap;
        uint256 aquaStrategyRelCap;
        uint256 aquaATokenAbsCap;
        uint256 aquaATokenRelCap;
        uint256 morphoStrategyAbsCap;
        uint256 morphoStrategyRelCap;
        uint256 morphoCollateralAbsCap;
        uint256 morphoCollateralRelCap;
        uint256 morphoMarketAbsCap;
        uint256 morphoMarketRelCap;
        uint256 offchainStrategyAbsCap;
        uint256 offchainStrategyRelCap;
        /* 7. strategy settings */
        address receiveSharesGate;
        address sendSharesGate;
        address receiveAssetsGate;
        address sendAssetsGate;
        uint256 aquaTargetBps;
        uint256 morphoTargetBps;
        uint256 offchainTargetBps;
        address skimRecipient;
        /* 8. morpho market */
        address morphoBlue;
        address morphoLoanToken;
        address morphoCollateralToken;
        address morphoOracle;
        address morphoIrm;
        uint256 morphoLltv;
        /* external wiring */
        address asset;
        address aavePool;
        address aToken;
        address morpho;
    }

    /// @dev Whether a config file is resolvable (CONFIG_FILE set, or a known chainid).
    function _configAvailable() internal view returns (bool) {
        if (bytes(vm.envOr("CONFIG_FILE", string(""))).length != 0) return true;
        uint256 id = block.chainid;
        return id == 421614 || id == 42161;
    }

    function _configPath() internal view returns (string memory) {
        string memory override_ = vm.envOr("CONFIG_FILE", string(""));
        if (bytes(override_).length != 0) return override_;
        uint256 id = block.chainid;
        if (id == 421614) return "config/arbitrum_sepolia.json";
        if (id == 42161) return "config/arbitrum.json";
        revert(
            string.concat("DeployConfig: no config for chainid ", vm.toString(id), " (set CONFIG_FILE to override)")
        );
    }

    /// @dev Reads and parses the full network config; every field falls back to its DEFAULT when absent.
    function _loadConfig() internal view returns (Config memory c) {
        string memory j = vm.readFile(_configPath());

        // 1. roles
        c.curator = j.readAddressOr(".roles.curator", address(0));
        c.sentinel = j.readAddressOr(".roles.sentinel", address(0));
        c.allocator = j.readAddressOr(".roles.allocator", address(0));
        c.offchainManager = j.readAddressOr(".roles.offchainManager", address(0));
        c.offchainReporter = j.readAddressOr(".roles.offchainReporter", address(0));

        // 2. fee values
        c.depositFee = j.readUintOr(".fees.depositFee", 0);
        c.withdrawalFee = j.readUintOr(".fees.withdrawalFee", 0);
        c.performanceFee = j.readUintOr(".fees.performanceFee", 0);
        c.managementFee = j.readUintOr(".fees.managementFee", 0);
        c.maxRate = j.readUintOr(".fees.maxRate", DEFAULT_MAX_RATE);
        c.forceDeallocatePenalty = j.readUintOr(".fees.forceDeallocatePenalty", 0);

        // 3. fee recipients
        c.protocolFeeRecipient = j.readAddressOr(".fees.protocolFeeRecipient", address(0));
        c.performanceFeeRecipient = j.readAddressOr(".fees.performanceFeeRecipient", address(0));
        c.managementFeeRecipient = j.readAddressOr(".fees.managementFeeRecipient", address(0));

        // 4. timelock
        c.timelockHigh = j.readUintOr(".timelock.highRisk", DEFAULT_TL_HIGH);
        c.timelockMedium = j.readUintOr(".timelock.mediumRisk", DEFAULT_TL_MEDIUM);
        c.timelockLow = j.readUintOr(".timelock.lowRisk", DEFAULT_TL_LOW);

        // 5. offchain
        c.stalePeriod = j.readUintOr(".offchain.stalePeriod", DEFAULT_STALE_PERIOD);
        c.maxChangeBps = j.readUintOr(".offchain.maxChangeBps", DEFAULT_MAX_CHANGE_BPS);
        c.custodian = j.readAddressOr(".offchain.custodian", address(0));

        // 6. caps
        c.aquaStrategyAbsCap = j.readUintOr(".caps.aquaStrategy.absolute", DEFAULT_CAP_ABS);
        c.aquaStrategyRelCap = j.readUintOr(".caps.aquaStrategy.relative", DEFAULT_CAP_REL);
        c.aquaATokenAbsCap = j.readUintOr(".caps.aquaAToken.absolute", DEFAULT_CAP_ABS);
        c.aquaATokenRelCap = j.readUintOr(".caps.aquaAToken.relative", DEFAULT_CAP_REL);
        c.morphoStrategyAbsCap = j.readUintOr(".caps.morphoStrategy.absolute", DEFAULT_CAP_ABS);
        c.morphoStrategyRelCap = j.readUintOr(".caps.morphoStrategy.relative", DEFAULT_CAP_REL);
        c.morphoCollateralAbsCap = j.readUintOr(".caps.morphoCollateral.absolute", DEFAULT_CAP_ABS);
        c.morphoCollateralRelCap = j.readUintOr(".caps.morphoCollateral.relative", DEFAULT_CAP_REL);
        c.morphoMarketAbsCap = j.readUintOr(".caps.morphoMarket.absolute", DEFAULT_CAP_ABS);
        c.morphoMarketRelCap = j.readUintOr(".caps.morphoMarket.relative", DEFAULT_CAP_REL);
        c.offchainStrategyAbsCap = j.readUintOr(".caps.offchainStrategy.absolute", DEFAULT_CAP_ABS);
        c.offchainStrategyRelCap = j.readUintOr(".caps.offchainStrategy.relative", DEFAULT_CAP_REL);

        // 7. strategy settings
        c.receiveSharesGate = j.readAddressOr(".strategy.receiveSharesGate", address(0));
        c.sendSharesGate = j.readAddressOr(".strategy.sendSharesGate", address(0));
        c.receiveAssetsGate = j.readAddressOr(".strategy.receiveAssetsGate", address(0));
        c.sendAssetsGate = j.readAddressOr(".strategy.sendAssetsGate", address(0));
        c.aquaTargetBps = j.readUintOr(".strategy.aquaTargetBps", 0);
        c.morphoTargetBps = j.readUintOr(".strategy.morphoTargetBps", 0);
        c.offchainTargetBps = j.readUintOr(".strategy.offchainTargetBps", 0);
        c.skimRecipient = j.readAddressOr(".strategy.skimRecipient", address(0));

        // 8. morpho market
        c.morphoBlue = j.readAddressOr(".morpho.morphoBlue", address(0));
        c.morphoLoanToken = j.readAddressOr(".morpho.loanToken", address(0));
        c.morphoCollateralToken = j.readAddressOr(".morpho.collateralToken", address(0));
        c.morphoOracle = j.readAddressOr(".morpho.oracle", address(0));
        c.morphoIrm = j.readAddressOr(".morpho.irm", address(0));
        c.morphoLltv = j.readUintOr(".morpho.lltv", DEFAULT_LLTV);

        // external
        c.asset = j.readAddressOr(".external.asset", address(0));
        c.aavePool = j.readAddressOr(".external.aavePool", address(0));
        c.aToken = j.readAddressOr(".external.aToken", address(0));
        c.morpho = j.readAddressOr(".external.morpho", address(0));
        if (c.morphoBlue == address(0)) c.morphoBlue = c.morpho; // alias
    }
}
