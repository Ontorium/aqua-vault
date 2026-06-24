// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {EnvSigner} from "../EnvSigner.sol";

/// @notice Step 3/7 — deploy the VaultFactory. The factory is RoleManager-agnostic: it accepts the
/// shared RoleManager address per `createVault` call. Deploy once and reuse across all vault deploys.
///
/// Required env: PRIVATE_KEY or MNEMONIC.
///
/// Usage:
///   forge script script/deploy/03_DeployVaultFactory.s.sol \
///     --rpc-url arbitrum_sepolia --broadcast
///
/// Next: export VAULT_FACTORY=<printed address> and (optional) 04_DeployMockAsset for testnet, then 05_CreateVault.
contract DeployVaultFactory is EnvSigner {
    function run() external {
        _startBroadcastFromEnv();
        VaultFactory factory = new VaultFactory();
        vm.stopBroadcast();

        console.log("=== VaultFactory deployed ===");
        console.log("address:", address(factory));
        console.log("");
        console.log("Next: export VAULT_FACTORY=", address(factory));
    }
}
