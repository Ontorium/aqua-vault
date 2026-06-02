// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {Timelock} from "../../src/Timelock.sol";
import {EnvSigner} from "../EnvSigner.sol";

/// @notice Step 2/7 — deploy the shared Timelock against the existing RoleManager, register its scope,
/// and bootstrap the timelock crew (GOVERNANCE/CURATOR/SENTINEL) onto the OWNER. After this the owner
/// can drive the Timelock end-to-end (configure targets / schedule / revoke).
///
/// Args: roleManager (RoleManager from step 01).
/// Required env: PRIVATE_KEY or MNEMONIC.
/// Optional env: OWNER (defaults to signer).
///
/// Usage:
///   forge script script/deploy/02_DeployTimelock.s.sol \
///     --sig "run(address)" 0xRoleManager \
///     --rpc-url arbitrum_sepolia --broadcast
///
/// Next: pass the printed Timelock address to 07/08.
contract DeployTimelock is EnvSigner {
    function run(address rmAddr) external {
        RoleManager rm = RoleManager(rmAddr);

        address signer = _startBroadcastFromEnv();
        address owner = _resolveOwner(signer);

        Timelock tl = new Timelock(address(rm));
        rm.registerScope(address(tl));
        rm.grantRole(rm.getScopedRole(address(tl), "GOVERNANCE_ROLE"), owner);
        rm.grantRole(rm.getScopedRole(address(tl), "CURATOR_ROLE"), owner);
        rm.grantRole(rm.getScopedRole(address(tl), "SENTINEL_ROLE"), owner);

        vm.stopBroadcast();

        console.log("=== Timelock deployed ===");
        console.log("address    :", address(tl));
        console.log("RoleManager:", address(rm));
        console.log("owner crew :", owner, "(GOVERNANCE + CURATOR + SENTINEL on timelock scope)");
        console.log("");
        console.log("Next: pass this TIMELOCK address to 07/08 ->", address(tl));
    }

    function _resolveOwner(address signer) internal view returns (address) {
        string memory ownerEnv = vm.envOr("OWNER", string(""));
        return bytes(ownerEnv).length == 0 ? signer : vm.parseAddress(ownerEnv);
    }
}
