// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.28;

import {Timelock} from "./Timelock.sol";
import {Vault} from "./Vault.sol";
import {StrategyManager} from "./StrategyManager.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";

contract VaultFactory is IVaultFactory {
    mapping(address account => bool) public isVault;
    mapping(address owner => mapping(address asset => mapping(bytes32 salt => address))) public vault;
    mapping(address vault => address strategyManager) public strategyManagerOf;
    mapping(address vault => address governance) public governanceOf;

    /// @dev Atomically deploys a Timelock, Vault and dedicated StrategyManager and links them.
    /// @dev The factory temporarily owns both governance and vault so it can complete first-time wiring.
    function createVault(address owner, address asset, bytes32 salt)
        external
        returns (address newVault, address newStrategyManager, address newGovernance)
    {
        Timelock g = new Timelock(address(this), owner);
        newGovernance = address(g);

        Vault v = new Vault{salt: salt}(address(this), asset);
        newVault = address(v);

        newStrategyManager = address(new StrategyManager(newVault, asset));

        g.setIsTarget(newVault, true);
        g.setIsTarget(newStrategyManager, true);

        v.setStrategyManager(newStrategyManager);
        v.setOwner(newGovernance);
        g.setOwner(owner);

        isVault[newVault] = true;
        vault[owner][asset][salt] = newVault;
        strategyManagerOf[newVault] = newStrategyManager;
        governanceOf[newVault] = newGovernance;

        emit CreateVault(owner, asset, salt, newVault, newStrategyManager, newGovernance);
    }
}
