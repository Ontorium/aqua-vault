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

    /// @dev Deploys only the Vault (the minimum its constructor depends on) against the given (shared)
    /// `roleManager`, and registers the new vault as its own role scope so per-vault GOVERNANCE can manage
    /// that vault's CURATOR/SENTINEL/ALLOCATOR. Pass the same shared RoleManager for every vault. The
    /// StrategyManager and Timelock are deployed and wired separately by the deployer — embedding all of
    /// them here would push the factory past the EIP-170 24KB code-size limit.
    ///
    /// Post-conditions the caller must complete (see script/Deploy.s.sol):
    ///   - deploy StrategyManager(vault, asset, roleManager) and (re)use the shared Timelock(roleManager);
    ///   - grant scoped(vault, GOVERNANCE) (admin = the RoleManager's DEFAULT_ADMIN), call
    ///     Vault.setStrategyManager, then hand scoped(vault, GOVERNANCE) to the Timelock.
    function createVault(address roleManager, address owner, address asset, bytes32 salt)
        external
        returns (address newVault)
    {
        require(roleManager != address(0), ErrorsLib.ZeroAddress());

        Vault v = new Vault{salt: salt}(roleManager, asset);
        newVault = address(v);

        // Wire the per-vault GOVERNANCE→operational admin hierarchy in the shared RoleManager.
        RoleManager(roleManager).registerScope(newVault);

        isVault[newVault] = true;
        vault[owner][asset][salt] = newVault;

        emit CreateVault(owner, asset, salt, newVault, roleManager);
    }
}
