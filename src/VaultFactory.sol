// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.28;

import {RoleManager} from "./RoleManager.sol";
import {Vault} from "./Vault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";

contract VaultFactory is IVaultFactory {
    mapping(address account => bool) public isVault;
    mapping(address owner => mapping(address asset => mapping(bytes32 salt => address))) public vault;
    mapping(address vault => address roleManager) public roleManagerOf;

    /// @dev Deploys only the minimum the Vault constructor depends on: a RoleManager and the Vault
    /// itself (`owner` becomes DEFAULT_ADMIN_ROLE on the RoleManager). The StrategyManager and Timelock
    /// are deployed and wired separately by the deployer — embedding all four contracts' creation code
    /// here would push the factory past the EIP-170 24KB code-size limit, making it undeployable.
    ///
    /// Post-conditions the caller must complete (see script/Deploy.s.sol):
    ///   - deploy StrategyManager(vault, asset, roleManager) and Timelock(roleManager);
    ///   - grant GOVERNANCE_ROLE (admin = owner), call Vault.setStrategyManager, hand GOVERNANCE to the Timelock.
    function createVault(address owner, address asset, bytes32 salt)
        external
        returns (address newVault, address newRoleManager)
    {
        RoleManager rm = new RoleManager(owner);
        newRoleManager = address(rm);

        Vault v = new Vault{salt: salt}(newRoleManager, asset);
        newVault = address(v);

        isVault[newVault] = true;
        vault[owner][asset][salt] = newVault;
        roleManagerOf[newVault] = newRoleManager;

        emit CreateVault(owner, asset, salt, newVault, newRoleManager);
    }
}
