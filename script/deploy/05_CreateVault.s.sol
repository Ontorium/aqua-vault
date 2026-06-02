// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {StrategyManager} from "../../src/StrategyManager.sol";
import {EnvSigner} from "../EnvSigner.sol";

/// @notice Step 5/7 — create a new vault via the factory (registers the vault's role scope automatically)
/// and deploy a dedicated StrategyManager for it.
///
/// Args: vaultFactory (step 03), roleManager (step 01), asset (underlying ERC20).
/// Required env: PRIVATE_KEY or MNEMONIC.
/// Optional env: OWNER (defaults to signer), SALT (bytes32, default 0).
///
/// Usage:
///   forge script script/deploy/05_CreateVault.s.sol \
///     --sig "run(address,address,address)" 0xVaultFactory 0xRoleManager 0xAsset \
///     --rpc-url arbitrum_sepolia --broadcast
///
/// Next: pass the printed VAULT + STRATEGY_MANAGER addresses to 06_WireVault.
contract CreateVault is EnvSigner {
    function run(address factoryAddr, address rm, address asset) external {
        VaultFactory factory = VaultFactory(factoryAddr);
        bytes32 salt = vm.envOr("SALT", bytes32(0));

        address signer = _startBroadcastFromEnv();
        address owner = _resolveOwner(signer);

        address vault = factory.createVault(rm, owner, asset, salt);
        address sm = address(new StrategyManager(vault, asset, rm));

        vm.stopBroadcast();

        console.log("=== Vault created ===");
        console.log("Vault            :", vault);
        console.log("StrategyManager  :", sm);
        console.log("RoleManager      :", rm);
        console.log("asset            :", asset);
        console.log("owner (initial)  :", owner);
        console.log("");
        console.log("Next: pass to 06_WireVault -> VAULT=", vault);
        console.log("                              STRATEGY_MANAGER=", sm);
    }

    function _resolveOwner(address signer) internal view returns (address) {
        string memory ownerEnv = vm.envOr("OWNER", string(""));
        return bytes(ownerEnv).length == 0 ? signer : vm.parseAddress(ownerEnv);
    }
}
