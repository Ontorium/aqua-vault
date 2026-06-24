// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {EnvSigner} from "../EnvSigner.sol";

/// @notice Step 1/7 — deploy the single shared RoleManager. The broadcasting signer is granted
/// DEFAULT_ADMIN_ROLE automatically (the RoleManager constructor handles this) unless OWNER is set.
///
/// Required env: PRIVATE_KEY or MNEMONIC.
/// Optional env: OWNER (defaults to signer).
///
/// Usage:
///   forge script script/deploy/01_DeployRoleManager.s.sol \
///     --rpc-url arbitrum_sepolia --broadcast
///
/// Next: export ROLE_MANAGER=<printed address> and run 02_DeployTimelock.
contract DeployRoleManager is EnvSigner {
    function run() external {
        address signer = _startBroadcastFromEnv();
        address owner = _resolveOwner(signer);

        RoleManager rm = new RoleManager(owner);

        vm.stopBroadcast();

        console.log("=== RoleManager deployed ===");
        console.log("address    :", address(rm));
        console.log("owner      :", owner);
        console.log("");
        console.log("Next: export ROLE_MANAGER=", address(rm));
    }

    function _resolveOwner(address signer) internal view returns (address) {
        string memory ownerEnv = vm.envOr("OWNER", string(""));
        return bytes(ownerEnv).length == 0 ? signer : vm.parseAddress(ownerEnv);
    }
}
