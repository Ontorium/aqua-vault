// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {Vault} from "../../src/Vault.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {EnvSigner} from "../EnvSigner.sol";
import {DeployConfig} from "../DeployConfig.sol";

/// @notice Applies the VAULT-level tunables from the network config to an already-deployed vault:
/// fee recipients, fee values (deposit/withdrawal/performance/management), maxRate, and the 4 gates.
/// Missing config keys fall back to DeployConfig defaults (fees 0, maxRate ~100% APR, gates none).
///
/// Recipients are set BEFORE their fees (the vault's fee setters require a recipient when fee > 0).
/// Signer must hold DEFAULT_ADMIN_ROLE (self-grants vault GOVERNANCE); revoke separately for prod.
///
///   forge script script/deploy/ConfigureVault.s.sol --sig "run(address,address)" 0xVault 0xRoleManager \
///     --rpc-url arbitrum_sepolia --broadcast
contract ConfigureVault is EnvSigner, DeployConfig {
    function run(address vaultAddr, address rmAddr) external {
        require(_configAvailable(), "no config for this chain (set CONFIG_FILE)");
        Config memory c = _loadConfig();
        Vault vault = Vault(vaultAddr);
        RoleManager rm = RoleManager(rmAddr);

        address signer = _startBroadcastFromEnv();
        bytes32 gov = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        if (!rm.hasRole(gov, signer)) rm.grantRole(gov, signer);

        // 1. recipients first (fee setters require a recipient when fee > 0)
        if (c.protocolFeeRecipient != address(0)) vault.setProtocolFeeRecipient(c.protocolFeeRecipient);
        if (c.performanceFeeRecipient != address(0)) vault.setPerformanceFeeRecipient(c.performanceFeeRecipient);
        if (c.managementFeeRecipient != address(0)) vault.setManagementFeeRecipient(c.managementFeeRecipient);

        // 2. fee values
        vault.setDepositFee(c.depositFee);
        vault.setWithdrawalFee(c.withdrawalFee);
        vault.setPerformanceFee(c.performanceFee);
        vault.setManagementFee(c.managementFee);

        // 3. maxRate
        vault.setMaxRate(c.maxRate);

        // 4. gates (only when configured)
        if (c.receiveSharesGate != address(0)) vault.setReceiveSharesGate(c.receiveSharesGate);
        if (c.sendSharesGate != address(0)) vault.setSendSharesGate(c.sendSharesGate);
        if (c.receiveAssetsGate != address(0)) vault.setReceiveAssetsGate(c.receiveAssetsGate);
        if (c.sendAssetsGate != address(0)) vault.setSendAssetsGate(c.sendAssetsGate);

        vm.stopBroadcast();

        console.log("=== ConfigureVault applied ===");
        console.log("vault:", vaultAddr);
        console.log("depositFee/withdrawalFee:", c.depositFee, c.withdrawalFee);
        console.log("performanceFee/managementFee:", c.performanceFee, c.managementFee);
        console.log("maxRate:", c.maxRate);
        console.log("protocol/perf/mgmt recipient:", c.protocolFeeRecipient, c.performanceFeeRecipient, c.managementFeeRecipient);
    }
}
