// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract FactoryTest is BaseTest {
    function testCreateVaultBookkeeping() public view {
        // setUp() created the canonical vault via the factory; verify the bookkeeping.
        assertTrue(vaultFactory.isVault(address(vault)));
        assertEq(vaultFactory.vault(owner, address(underlyingToken), bytes32(0)), address(vault));
        assertEq(vaultFactory.roleManagerOf(address(vault)), address(roleManager));
    }

    function testCreateVaultWiresGovernanceCorrectly() public view {
        // Owner is the sole DEFAULT_ADMIN; the factory never holds any role. Timelock GOVERNANCE and
        // the Vault->StrategyManager link are wired by setUp() (the deployer's job post-factory).
        assertTrue(roleManager.hasRole(roleManager.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(roleManager.hasRole(roleManager.GOVERNANCE_ROLE(), address(timelock)));
        assertFalse(roleManager.hasRole(roleManager.GOVERNANCE_ROLE(), address(vaultFactory)));
        assertFalse(roleManager.hasRole(roleManager.DEFAULT_ADMIN_ROLE(), address(vaultFactory)));

        // Vault knows its strategyManager and the strategyManager points back.
        assertEq(vault.strategyManager(), address(strategyManager));
        assertEq(strategyManager.vault(), address(vault));
        assertEq(strategyManager.asset(), address(underlyingToken));
    }

    function testCreateVaultIsDeterministic(address _owner, bytes32 salt) public {
        vm.assume(_owner != address(0));
        vm.assume(_owner != owner || salt != bytes32(0)); // skip the slot setUp() already used

        ERC20Mock token = new ERC20Mock(18);

        vm.expectEmit(true, true, false, false);
        emit IVaultFactory.CreateVault(_owner, address(token), salt, address(0), address(0));

        (address newVault,) = vaultFactory.createVault(_owner, address(token), salt);
        assertTrue(vaultFactory.isVault(newVault));
        assertEq(vaultFactory.vault(_owner, address(token), salt), newVault);
    }

    function testCreateVaultUsesCreate2Salt() public {
        ERC20Mock token = new ERC20Mock(18);
        bytes32 saltA = bytes32(uint256(1));
        bytes32 saltB = bytes32(uint256(2));

        (address vaultA,) = vaultFactory.createVault(owner, address(token), saltA);
        (address vaultB,) = vaultFactory.createVault(owner, address(token), saltB);
        assertTrue(vaultA != vaultB, "different salts must produce different addresses");
    }
}
