// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {Timelock} from "../../src/Timelock.sol";
import {EnvSigner} from "../EnvSigner.sol";

/// @notice Step 7/7 — register the vault and its StrategyManager as governance targets on the Timelock.
/// Without this, `timelock.schedule(target, ...)` reverts InvalidTarget for any call into them.
/// @dev The signer must hold scoped(timelock, GOVERNANCE_ROLE) — bootstrapped in step 02.
///
/// Args: timelock (step 02), vault (step 05), strategyManager (step 05).
/// Required env: PRIVATE_KEY or MNEMONIC.
///
/// Usage:
///   forge script script/deploy/07_RegisterTimelockTargets.s.sol \
///     --sig "run(address,address,address)" 0xTimelock 0xVault 0xStrategyManager \
///     --rpc-url arbitrum_sepolia --broadcast
contract RegisterTimelockTargets is EnvSigner {
    function run(address timelockAddr, address vault, address sm) external {
        Timelock timelock = Timelock(timelockAddr);

        _startBroadcastFromEnv();

        timelock.setIsTarget(vault, true);
        timelock.setIsTarget(sm, true);

        vm.stopBroadcast();

        console.log("=== Timelock targets registered ===");
        console.log("Timelock         :", address(timelock));
        console.log("target: Vault    :", vault);
        console.log("target: StratMgr :", sm);
        console.log("");
        console.log("Deployment complete. Use timelock.schedule/execute for any governance change.");
    }
}
