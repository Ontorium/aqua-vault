// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {Vault} from "../../src/Vault.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {WAD} from "../../src/libraries/ConstantsLib.sol";
import {EnvSigner} from "../EnvSigner.sol";
import {DeployConfig} from "../DeployConfig.sol";

/// @notice Step 11 — set the vault's `maxRate` (per-second growth cap for `totalAssets`).
/// Without this, `accrueInterest()` cannot credit strategy yield to `sharePrice` because the
/// growth is clamped at `_totalAssets * elapsed * maxRate / WAD` and `maxRate = 0` zeroes it out.
///
/// The signer self-grants vault-scoped GOVERNANCE (admined by DEFAULT_ADMIN_ROLE), calls
/// `setMaxRate`, and leaves the grant in place. Revoke separately once you want Timelock-only
/// governance restored.
///
/// MaxRate is per-second WAD scaled. Common pick: `100% APR` → `1e18 / (365 * 24 * 3600)`
/// ≈ `31_709_791_983`. The on-chain `MAX_MAX_RATE` is `2e18 / 365 days` (200% APR cap).
///
/// Args:
///   vault       Vault contract
///   roleManager Shared RoleManager
/// Optional env:
///   MAX_RATE    per-second WAD-scaled rate. Default = `1e18 / 365 days` (100% APR).
///
/// Usage (USDT vault, 100% APR cap):
///   forge script script/deploy/11_SetMaxRate.s.sol \
///     --sig "run(address,address)" \
///     0xD408A6B5425e9866dc05F68F2c75e8F2F7495d95 \
///     0x52815561C58731761DBfa302d0aE160712F7b331 \
///     --rpc-url arbitrum_sepolia --broadcast
contract SetMaxRate is EnvSigner, DeployConfig {
    function run(address vaultAddr, address rmAddr) external {
        Vault vault = Vault(vaultAddr);
        RoleManager rm = RoleManager(rmAddr);

        // MAX_RATE env > config.fees.maxRate > default (100% APR).
        uint256 defaultRate = _configAvailable() ? _loadConfig().maxRate : WAD / 365 days;
        uint256 newRate = vm.envOr("MAX_RATE", defaultRate);

        address signer = _startBroadcastFromEnv();

        bytes32 govRole = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        if (!rm.hasRole(govRole, signer)) rm.grantRole(govRole, signer);

        vault.setMaxRate(newRate);

        vm.stopBroadcast();

        console.log("=== maxRate set ===");
        console.log("vault       :", vaultAddr);
        console.log("newMaxRate  :", newRate, "(per-second, WAD-scaled)");
        console.log("approx APR%%:", (newRate * 365 days * 100) / WAD);
    }
}
