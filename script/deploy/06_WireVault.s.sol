// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {Vault} from "../../src/Vault.sol";
import {EnvSigner} from "../EnvSigner.sol";

/// @notice Step 6/7 — wire the new vault: OWNER transiently takes scoped(vault, GOVERNANCE), uses it to
/// link the StrategyManager and set the share token name/symbol, then hands GOVERNANCE off to the shared
/// Timelock and revokes their own grant. After this, the only holder of scoped(vault, GOVERNANCE) is the
/// Timelock — all future governance changes must go through it.
///
/// Args: roleManager (step 01), vault (step 05), strategyManager (step 05), timelock (step 02).
/// Required env: PRIVATE_KEY or MNEMONIC.
/// Optional env: OWNER, VAULT_NAME, VAULT_SYMBOL.
///
/// Usage:
///   export VAULT_NAME="Aqua Vault USDT" VAULT_SYMBOL="aquavUSDT"
///   forge script script/deploy/06_WireVault.s.sol \
///     --sig "run(address,address,address,address)" 0xRoleManager 0xVault 0xStrategyManager 0xTimelock \
///     --rpc-url arbitrum_sepolia --broadcast
contract WireVault is EnvSigner {
    function run(address rmAddr, address vaultAddr, address sm, address timelock) external {
        RoleManager rm = RoleManager(rmAddr);
        Vault vault = Vault(vaultAddr);

        string memory vaultName = vm.envOr("VAULT_NAME", string(""));
        string memory vaultSymbol = vm.envOr("VAULT_SYMBOL", string(""));

        address signer = _startBroadcastFromEnv();
        address owner = _resolveOwner(signer);

        bytes32 governanceRole = rm.getScopedRole(address(vault), "GOVERNANCE_ROLE");

        // (1) Transient GOV → owner so the wiring calls below pass onlyRole(GOV).
        rm.grantRole(governanceRole, owner);

        // (2) Wire StrategyManager + name/symbol.
        vault.setStrategyManager(sm);
        if (bytes(vaultName).length != 0) vault.setName(vaultName);
        if (bytes(vaultSymbol).length != 0) vault.setSymbol(vaultSymbol);

        // (3) Hand GOV to Timelock and revoke owner's grant — Timelock becomes the sole holder.
        rm.grantRole(governanceRole, timelock);
        rm.revokeRole(governanceRole, owner);

        vm.stopBroadcast();

        console.log("=== Vault wired ===");
        console.log("Vault            :", address(vault));
        console.log("StrategyManager  :", sm);
        console.log("Timelock         :", timelock, "(holds scoped(vault, GOVERNANCE))");
        console.log("share name       :", vault.name());
        console.log("share symbol     :", vault.symbol());
        console.log("");
        console.log("Next: run 07_RegisterTimelockTargets to opt vault + SM into Timelock governance.");
    }

    function _resolveOwner(address signer) internal view returns (address) {
        string memory ownerEnv = vm.envOr("OWNER", string(""));
        return bytes(ownerEnv).length == 0 ? signer : vm.parseAddress(ownerEnv);
    }
}
