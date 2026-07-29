// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {Vault} from "../../src/Vault.sol";
import {EnvSigner} from "../EnvSigner.sol";
import {DeployConfig} from "../DeployConfig.sol";

/// @notice Applies the per-network config (config/<network>.json) to a deployed vault: grants the
/// operational roles (CURATOR / SENTINEL / ALLOCATOR) and sets the fee recipients. Run AFTER the vault
/// exists (step 05); safe to run before or after the GOVERNANCE handoff (step 06).
///
/// @dev The signer must hold DEFAULT_ADMIN_ROLE (the deployer/owner). DEFAULT_ADMIN is the admin of the
/// GOVERNANCE role, so this script transiently grants scoped(vault, GOVERNANCE) to the signer to perform
/// the grants/setters, then revokes it — leaving the Timelock as the sole standing GOVERNANCE holder.
/// Operational role holders come ONLY from the config file, never from env or the deployer.
///
/// Args: roleManager (step 01), vault (step 05).
/// Required env: PRIVATE_KEY or MNEMONIC (must hold DEFAULT_ADMIN_ROLE).
/// Optional env: CONFIG_FILE (override the chainid-based config path).
///
/// Usage:
///   forge script script/deploy/GrantRoles.s.sol \
///     --sig "run(address,address)" 0xRoleManager 0xVault \
///     --rpc-url arbitrum_sepolia --broadcast
contract GrantRoles is EnvSigner, DeployConfig {
    function run(address rmAddr, address vaultAddr) external {
        RoleManager rm = RoleManager(rmAddr);
        Vault vault = Vault(vaultAddr);
        Config memory c = _loadConfig();

        address signer = _startBroadcastFromEnv();

        bytes32 gov = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");

        // Transiently take GOVERNANCE so the role grants (admin = scoped vault GOV) and the fee-recipient
        // setters (onlyRole GOV) pass. Requires the signer to hold DEFAULT_ADMIN_ROLE.
        bool tookGov = !rm.hasRole(gov, signer);
        if (tookGov) rm.grantRole(gov, signer);

        // Operational roles — source of truth is the config file.
        if (c.curator != address(0)) {
            rm.grantRole(rm.getScopedRole(vaultAddr, "CURATOR_ROLE"), c.curator);
        }
        if (c.sentinel != address(0)) {
            rm.grantRole(rm.getScopedRole(vaultAddr, "SENTINEL_ROLE"), c.sentinel);
        }
        if (c.allocator != address(0)) {
            rm.grantRole(rm.getScopedRole(vaultAddr, "ALLOCATOR_ROLE"), c.allocator);
        }

        // Fee recipients (governance-gated vault setters).
        if (c.protocolFeeRecipient != address(0)) vault.setProtocolFeeRecipient(c.protocolFeeRecipient);
        if (c.performanceFeeRecipient != address(0)) vault.setPerformanceFeeRecipient(c.performanceFeeRecipient);
        if (c.managementFeeRecipient != address(0)) vault.setManagementFeeRecipient(c.managementFeeRecipient);

        // Hand GOVERNANCE back (Timelock remains the standing holder; signer keeps only DEFAULT_ADMIN).
        if (tookGov) rm.revokeRole(gov, signer);

        vm.stopBroadcast();

        console.log("=== Roles applied from %s ===", _configPath());
        console.log("Vault     :", vaultAddr);
        console.log("curator   :", c.curator);
        console.log("sentinel  :", c.sentinel);
        console.log("allocator :", c.allocator);
        console.log("protocolFeeRecipient    :", c.protocolFeeRecipient);
        console.log("performanceFeeRecipient :", c.performanceFeeRecipient);
        console.log("managementFeeRecipient  :", c.managementFeeRecipient);
        console.log("");
        console.log("NOTE: offchain manager/reporter are per-strategy roles - grant them at strategy deploy.");
    }
}
