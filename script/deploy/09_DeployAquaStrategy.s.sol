// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {AquaStrategy} from "../../src/strategies/AquaStrategy.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {StrategyManager} from "../../src/StrategyManager.sol";
import {Vault} from "../../src/Vault.sol";
import {WAD} from "../../src/libraries/ConstantsLib.sol";
import {EnvSigner} from "../EnvSigner.sol";

/// @notice Step 9 — deploy an AquaStrategy for an existing vault and wire it into the vault's
/// StrategyManager. The signer self-grants the vault-scoped GOVERNANCE_ROLE (admined by
/// DEFAULT_ADMIN_ROLE), registers the strategy as kind=1 (ONCHAIN), and lifts caps to max for both
/// emitted ids (adapter + aToken).
///
/// Repeat once per vault: each vault needs its OWN AquaStrategy instance because the strategy
/// address is bound to a single (vault, asset, aToken) tuple at construction.
///
/// Args:
///   vault           Vault contract (its `asset()` is read to wire the strategy)
///   lendingPool     Aqua / Aave-V2 lending pool
///   aToken          receipt aToken for `vault.asset()` on `lendingPool`
///   strategyManager Vault's StrategyManager (per-vault instance)
///   roleManager     Shared RoleManager
///
/// Required env: PRIVATE_KEY or MNEMONIC (signer must hold DEFAULT_ADMIN_ROLE on RoleManager).
///
/// Usage (USDT vault):
///   forge script script/deploy/09_DeployAquaStrategy.s.sol \
///     --sig "run(address,address,address,address,address)" \
///     0xUSDTVault 0xAquaPool 0xAUSDT 0xUSDTStrategyManager 0xRoleManager \
///     --rpc-url arbitrum_sepolia --broadcast
contract DeployAquaStrategy is EnvSigner {
    function run(
        address vaultAddr,
        address lendingPool,
        address aToken,
        address smAddr,
        address rmAddr
    ) external {
        Vault vault = Vault(vaultAddr);
        address asset = vault.asset();
        RoleManager rm = RoleManager(rmAddr);
        StrategyManager sm = StrategyManager(smAddr);

        address signer = _startBroadcastFromEnv();

        // 1. Deploy.
        AquaStrategy strategy = new AquaStrategy(vaultAddr, asset, lendingPool, aToken, rmAddr);

        // 2. Self-grant vault-scoped GOVERNANCE. Signer must hold DEFAULT_ADMIN_ROLE (the global
        //    admin of every scoped GOVERNANCE_ROLE). Leave the grant in place; revoke separately
        //    once you want to restore Timelock-only governance.
        bytes32 govRole = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        rm.grantRole(govRole, signer);

        // 3. Register strategy (kind=1: ONCHAIN, capBps=0/targetBps=0 keeps shares allocation
        //    unconstrained at the SM-share level; the per-id caps below are what bound flow).
        sm.addStrategy(address(strategy), 1, 0, 0);

        // 4. Lift caps for both ids the strategy emits: the adapter id (strategy-level aggregate)
        //    and the aToken id (cross-strategy aggregate per aToken). Both must permit flow or
        //    allocate() reverts on the smaller of the two.
        bytes memory adapterIdData = abi.encode("AquaStrategy", address(strategy));
        bytes memory aTokenIdData = abi.encode("aToken", aToken);
        sm.increaseAbsoluteCap(adapterIdData, type(uint128).max);
        sm.increaseRelativeCap(adapterIdData, WAD);
        sm.increaseAbsoluteCap(aTokenIdData, type(uint128).max);
        sm.increaseRelativeCap(aTokenIdData, WAD);

        vm.stopBroadcast();

        console.log("=== AquaStrategy deployed + wired ===");
        console.log("strategy        :", address(strategy));
        console.log("vault           :", vaultAddr);
        console.log("asset           :", asset);
        console.log("lendingPool     :", lendingPool);
        console.log("aToken          :", aToken);
        console.log("strategyManager :", smAddr);
        console.log("");
        console.log("Signer now holds scoped(vault, GOVERNANCE_ROLE). To restore Timelock-only");
        console.log("governance later, revoke via:");
        console.log("  rm.revokeRole(rm.getScopedRole(vault, 'GOVERNANCE_ROLE'), signer)");
    }
}
