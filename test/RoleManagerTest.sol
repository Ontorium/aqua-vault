// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {Test} from "../lib/forge-std/src/Test.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {IRoleManager} from "../src/interfaces/IRoleManager.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";

contract RoleManagerTest is Test {
    RoleManager internal rm;

    address internal immutable admin = makeAddr("admin");
    address internal immutable alice = makeAddr("alice");
    address internal immutable bob = makeAddr("bob");

    bytes32 internal GOVERNANCE_ROLE;
    bytes32 internal CURATOR_ROLE;
    bytes32 internal SENTINEL_ROLE;
    bytes32 internal ALLOCATOR_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE;

    function setUp() public {
        rm = new RoleManager(admin);
        GOVERNANCE_ROLE = rm.GOVERNANCE_ROLE();
        CURATOR_ROLE = rm.CURATOR_ROLE();
        SENTINEL_ROLE = rm.SENTINEL_ROLE();
        ALLOCATOR_ROLE = rm.ALLOCATOR_ROLE();
        DEFAULT_ADMIN_ROLE = rm.DEFAULT_ADMIN_ROLE();
    }

    function testConstructorRejectsZeroAdmin() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new RoleManager(address(0));
    }

    function testAdminBootstrap() public view {
        assertTrue(rm.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(rm.getRoleAdmin(GOVERNANCE_ROLE), DEFAULT_ADMIN_ROLE);
        assertEq(rm.getRoleAdmin(CURATOR_ROLE), GOVERNANCE_ROLE);
        assertEq(rm.getRoleAdmin(SENTINEL_ROLE), GOVERNANCE_ROLE);
        assertEq(rm.getRoleAdmin(ALLOCATOR_ROLE), GOVERNANCE_ROLE);
    }

    function testGrantRoleByRoleAdmin() public {
        // Admin grants governance.
        vm.expectEmit();
        emit IRoleManager.RoleGranted(GOVERNANCE_ROLE, alice, admin);
        vm.prank(admin);
        rm.grantRole(GOVERNANCE_ROLE, alice);
        assertTrue(rm.hasRole(GOVERNANCE_ROLE, alice));

        // Governance grants curator.
        vm.expectEmit();
        emit IRoleManager.RoleGranted(CURATOR_ROLE, bob, alice);
        vm.prank(alice);
        rm.grantRole(CURATOR_ROLE, bob);
        assertTrue(rm.hasRole(CURATOR_ROLE, bob));
    }

    function testGrantRoleRejectsWrongAdmin(address rdm) public {
        vm.assume(rdm != admin);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        rm.grantRole(GOVERNANCE_ROLE, alice);
    }

    function testRevokeRole() public {
        vm.startPrank(admin);
        rm.grantRole(GOVERNANCE_ROLE, alice);

        vm.expectEmit();
        emit IRoleManager.RoleRevoked(GOVERNANCE_ROLE, alice, admin);
        rm.revokeRole(GOVERNANCE_ROLE, alice);
        vm.stopPrank();
        assertFalse(rm.hasRole(GOVERNANCE_ROLE, alice));
    }

    function testRenounceRoleRequiresSelfConfirmation() public {
        vm.prank(admin);
        rm.grantRole(GOVERNANCE_ROLE, alice);

        // Confirmation must equal msg.sender.
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(alice);
        rm.renounceRole(GOVERNANCE_ROLE, bob);

        // Self-confirmation works.
        vm.expectEmit();
        emit IRoleManager.RoleRevoked(GOVERNANCE_ROLE, alice, alice);
        vm.prank(alice);
        rm.renounceRole(GOVERNANCE_ROLE, alice);
        assertFalse(rm.hasRole(GOVERNANCE_ROLE, alice));
    }

    function testGrantRoleIsIdempotent() public {
        vm.prank(admin);
        rm.grantRole(GOVERNANCE_ROLE, alice);

        // Second grant is a no-op; no event re-emitted, and state unchanged.
        vm.recordLogs();
        vm.prank(admin);
        rm.grantRole(GOVERNANCE_ROLE, alice);
        assertEq(vm.getRecordedLogs().length, 0, "duplicate grant must not emit");
        assertTrue(rm.hasRole(GOVERNANCE_ROLE, alice));
    }

    function testSetRoleAdminReorgRequiresDefaultAdmin(address rdm) public {
        vm.assume(rdm != admin);

        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        rm.setRoleAdmin(CURATOR_ROLE, DEFAULT_ADMIN_ROLE);

        vm.expectEmit();
        emit IRoleManager.RoleAdminChanged(CURATOR_ROLE, GOVERNANCE_ROLE, DEFAULT_ADMIN_ROLE);
        vm.prank(admin);
        rm.setRoleAdmin(CURATOR_ROLE, DEFAULT_ADMIN_ROLE);
        assertEq(rm.getRoleAdmin(CURATOR_ROLE), DEFAULT_ADMIN_ROLE);
    }
}
