// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.28;

import {RoleManager} from "./RoleManager.sol";
import {Timelock} from "./Timelock.sol";
import {Vault} from "./Vault.sol";
import {StrategyManager} from "./StrategyManager.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";

contract VaultFactory is IVaultFactory {
    mapping(address account => bool) public isVault;
    mapping(address owner => mapping(address asset => mapping(bytes32 salt => address))) public vault;
    mapping(address vault => address strategyManager) public strategyManagerOf;
    mapping(address vault => address roleManager) public roleManagerOf;
    mapping(address vault => address timelock) public timelockOf;

    /// @dev Atomically deploys a RoleManager, Vault, dedicated StrategyManager, and Timelock; wires
    /// them; grants `owner` DEFAULT_ADMIN_ROLE; grants Timelock GOVERNANCE_ROLE; renounces factory
    /// privileges.
    function createVault(address owner, address asset, bytes32 salt)
        external
        returns (address newVault, address newStrategyManager, address newRoleManager, address newTimelock)
    {
        // 1. Deploy RoleManager with the factory as initial admin so it can perform wiring below.
        RoleManager rm = new RoleManager(address(this));
        newRoleManager = address(rm);

        // 2. Deploy Vault and StrategyManager pointing at the RoleManager.
        Vault v = new Vault{salt: salt}(newRoleManager, asset);
        newVault = address(v);

        newStrategyManager = address(new StrategyManager(newVault, asset, newRoleManager));

        // 3. Deploy Timelock and register Vault + StrategyManager as governance targets.
        Timelock t = new Timelock(newRoleManager);
        newTimelock = address(t);

        // The factory needs CURATOR/GOVERNANCE on the RoleManager to drive setup. Grant them.
        rm.grantRole(rm.GOVERNANCE_ROLE(), address(this));

        // Vault wires its StrategyManager (gated by GOVERNANCE_ROLE).
        v.setStrategyManager(newStrategyManager);

        // 4. Hand governance over to the Timelock (it becomes the only GOVERNANCE_ROLE holder).
        rm.grantRole(rm.GOVERNANCE_ROLE(), newTimelock);
        rm.revokeRole(rm.GOVERNANCE_ROLE(), address(this));

        // 5. Owner takes over RoleManager admin. Factory renounces.
        rm.grantRole(rm.DEFAULT_ADMIN_ROLE(), owner);
        rm.renounceRole(rm.DEFAULT_ADMIN_ROLE(), address(this));

        isVault[newVault] = true;
        vault[owner][asset][salt] = newVault;
        strategyManagerOf[newVault] = newStrategyManager;
        roleManagerOf[newVault] = newRoleManager;
        timelockOf[newVault] = newTimelock;

        emit CreateVault(owner, asset, salt, newVault, newStrategyManager, newRoleManager, newTimelock);
    }
}
