// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.28;

import {RoleManager} from "./RoleManager.sol";
import {Vault} from "./Vault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

contract VaultFactory is IVaultFactory {
    mapping(address account => bool) public isVault;
    mapping(address owner => mapping(address asset => mapping(bytes32 salt => address))) public vault;

    /// @dev Deploys a vault and registers it as a role scope in the shared RoleManager.
    /// StrategyManager and Timelock wiring is handled separately.
    function createVault(address roleManager, address owner, address asset, bytes32 salt)
        external
        returns (address newVault)
    {
        require(roleManager != address(0), ErrorsLib.ZeroAddress());

        Vault v = new Vault{salt: salt}(roleManager, asset);
        newVault = address(v);

        // Register the vault scope in the shared RoleManager.
        RoleManager(roleManager).registerScope(newVault);

        isVault[newVault] = true;
        vault[owner][asset][salt] = newVault;

        emit CreateVault(owner, asset, salt, newVault, roleManager);
    }
}
