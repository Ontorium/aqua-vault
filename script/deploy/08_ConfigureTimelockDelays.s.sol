// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {Timelock} from "../../src/Timelock.sol";
import {Vault} from "../../src/Vault.sol";
import {StrategyManager} from "../../src/StrategyManager.sol";
import {EnvSigner} from "../EnvSigner.sol";
import {DeployConfig} from "../DeployConfig.sol";

/// @notice Step 8 (OPTIONAL) — set per-(target,selector) delays on the Timelock. Default is 0 (no
/// delay), which is fine for local/test runs; before going to production you'll want non-zero values
/// on at least the high-risk governance functions.
///
/// Pick the preset via `DELAY_PRESET`:
///   - "test"   (default) — short delays for testnet/QA flow rehearsal (60s for high-risk, 0s otherwise)
///   - "mainnet"           — conservative defaults (14d fee/recipient, 7d strategy/cap, 3d misc)
///
/// Args: timelock (step 02), vault (step 05), strategyManager (step 05).
/// Required env: PRIVATE_KEY or MNEMONIC.
/// Optional env: DELAY_PRESET (default "test").
///
/// Usage:
///   export DELAY_PRESET=test
///   forge script script/deploy/08_ConfigureTimelockDelays.s.sol \
///     --sig "run(address,address,address)" 0xTimelock 0xVault 0xStrategyManager \
///     --rpc-url arbitrum_sepolia --broadcast
contract ConfigureTimelockDelays is EnvSigner, DeployConfig {
    function run(address timelockAddr, address vault, address sm) external {
        Timelock timelock = Timelock(timelockAddr);
        string memory preset = vm.envOr("DELAY_PRESET", string("test"));

        _startBroadcastFromEnv();

        bool isMainnet = keccak256(bytes(preset)) == keccak256(bytes("mainnet"));

        // Delays: config.timelock.{high,medium,low}Risk when a network config exists, else DELAY_PRESET.
        uint256 highRisk = isMainnet ? 14 days : 60;
        uint256 mediumRisk = isMainnet ? 7 days : 60;
        uint256 lowRisk = isMainnet ? 3 days : 0;
        if (_configAvailable()) {
            Config memory c = _loadConfig();
            highRisk = c.timelockHigh;
            mediumRisk = c.timelockMedium;
            lowRisk = c.timelockLow;
        }

        timelock.increaseTimelock(vault, Vault.setWithdrawalFee.selector,        highRisk);
        timelock.increaseTimelock(vault, Vault.setDepositFee.selector,           highRisk);
        timelock.increaseTimelock(vault, Vault.setPerformanceFee.selector,       highRisk);
        timelock.increaseTimelock(vault, Vault.setManagementFee.selector,        highRisk);
        timelock.increaseTimelock(vault, Vault.setProtocolFeeRecipient.selector, highRisk);
        timelock.increaseTimelock(vault, Vault.setPerformanceFeeRecipient.selector, highRisk);
        timelock.increaseTimelock(vault, Vault.setManagementFeeRecipient.selector,  highRisk);
        timelock.increaseTimelock(vault, Vault.setStrategyManager.selector,      highRisk);
        timelock.increaseTimelock(vault, Vault.setMaxRate.selector,              highRisk);

        // Medium (strategy add/remove/cap)
        timelock.increaseTimelock(sm, StrategyManager.addStrategy.selector,                mediumRisk);
        timelock.increaseTimelock(sm, StrategyManager.removeStrategy.selector,             mediumRisk);
        timelock.increaseTimelock(sm, StrategyManager.setStrategyActive.selector,          mediumRisk);
        timelock.increaseTimelock(sm, StrategyManager.increaseAbsoluteCap.selector,        mediumRisk);
        timelock.increaseTimelock(sm, StrategyManager.increaseRelativeCap.selector,        mediumRisk);
        timelock.increaseTimelock(sm, StrategyManager.setForceDeallocatePenalty.selector,  mediumRisk);

        // Low (metadata)
        timelock.increaseTimelock(vault, Vault.setName.selector,   lowRisk);
        timelock.increaseTimelock(vault, Vault.setSymbol.selector, lowRisk);
        timelock.increaseTimelock(vault, Vault.unpause.selector,   lowRisk);

        vm.stopBroadcast();

        console.log("=== Timelock delays configured ===");
        console.log("preset       :", preset);
        console.log("high-risk    :", highRisk, "s");
        console.log("medium-risk  :", mediumRisk, "s");
        console.log("low-risk     :", lowRisk, "s");
        console.log("");
        console.log("Add more selectors here as new governance functions are introduced.");
    }
}
