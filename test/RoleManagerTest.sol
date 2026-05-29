// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {Test} from "../lib/forge-std/src/Test.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {IAccessControl} from "../src/interfaces/IAccessControl.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {EventsLib} from "../src/libraries/EventsLib.sol";

contract RoleManagerTest is Test {
    RoleManager internal rm;

    address internal immutable admin = makeAddr("admin");
    address internal immutable alice = makeAddr("alice");
    address internal immutable bob = makeAddr("bob");

    /// @dev A stand-in vault address used as the role scope under test.
    address internal immutable scope = makeAddr("vaultScope");

    bytes32 internal DEFAULT_ADMIN_ROLE;
    // Scoped role ids (the only ids ever checked at runtime).
    bytes32 internal sGov;
    bytes32 internal sCur;
    bytes32 internal sSen;
    bytes32 internal sAlloc;

    function setUp() public {
        rm = new RoleManager(admin);
        DEFAULT_ADMIN_ROLE = rm.DEFAULT_ADMIN_ROLE();

        rm.registerScope(scope);
        sGov = rm.getScopedRole(scope, "GOVERNANCE_ROLE");
        sCur = rm.getScopedRole(scope, "CURATOR_ROLE");
        sSen = rm.getScopedRole(scope, "SENTINEL_ROLE");
        sAlloc = rm.getScopedRole(scope, "ALLOCATOR_ROLE");
    }

    function testConstructorRejectsZeroAdmin() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new RoleManager(address(0));
    }

    function testScopedRoleMatchesConvention() public view {
        // The scoped id derives from the role NAME hashed the same way AccessManaged checks it.
        assertEq(sGov, keccak256(abi.encode(scope, keccak256("GOVERNANCE_ROLE"))));
        assertEq(sGov, keccak256(abi.encode(scope, rm.GOVERNANCE_ROLE())));
        assertEq(rm.getScopedRole(scope, "CURATOR_ROLE"), sCur);
    }

    function testAdminBootstrap() public view {
        assertTrue(rm.hasRole(DEFAULT_ADMIN_ROLE, admin));
        // GOVERNANCE stays administered by the global DEFAULT_ADMIN; operational roles by the scope's GOVERNANCE.
        assertEq(rm.getRoleAdmin(sGov), DEFAULT_ADMIN_ROLE);
        assertEq(rm.getRoleAdmin(sCur), sGov);
        assertEq(rm.getRoleAdmin(sSen), sGov);
        assertEq(rm.getRoleAdmin(sAlloc), sGov);
    }

    function testRegisterScopeIsPermissionlessAndIdempotent(address rdm) public {
        address freshScope = makeAddr("freshScope");
        // Anyone may register (it grants no membership, only wires the deterministic admin hierarchy).
        vm.expectEmit();
        emit EventsLib.RegisterScope(freshScope);
        vm.prank(rdm);
        rm.registerScope(freshScope);
        assertTrue(rm.isScopeRegistered(freshScope));
        assertEq(rm.getRoleAdmin(rm.getScopedRole(freshScope, "CURATOR_ROLE")), rm.getScopedRole(freshScope, "GOVERNANCE_ROLE"));

        // Second call is a no-op: no event re-emitted.
        vm.recordLogs();
        rm.registerScope(freshScope);
        assertEq(vm.getRecordedLogs().length, 0, "re-register must not emit");
    }

    function testRegisterScopeRejectsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        rm.registerScope(address(0));
    }

    function testGrantRoleByRoleAdmin() public {
        // Admin (DEFAULT_ADMIN) grants the scope's governance.
        vm.expectEmit();
        emit IAccessControl.RoleGranted(sGov, alice, admin);
        vm.prank(admin);
        rm.grantRole(sGov, alice);
        assertTrue(rm.hasRole(sGov, alice));

        // The scope's governance grants the scope's curator.
        vm.expectEmit();
        emit IAccessControl.RoleGranted(sCur, bob, alice);
        vm.prank(alice);
        rm.grantRole(sCur, bob);
        assertTrue(rm.hasRole(sCur, bob));
    }

    function testGrantRoleRejectsWrongAdmin(address rdm) public {
        vm.assume(rdm != admin);
        // grantRole(scoped GOVERNANCE) requires its admin (DEFAULT_ADMIN_ROLE).
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, rdm, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(rdm);
        rm.grantRole(sGov, alice);
    }

    function testScopesAreIsolated() public {
        address other = makeAddr("otherVault");
        rm.registerScope(other);

        // Granting governance in one scope must not grant it in another.
        vm.prank(admin);
        rm.grantRole(sGov, alice);
        assertTrue(rm.hasRole(sGov, alice));
        assertFalse(rm.hasRole(rm.getScopedRole(other, "GOVERNANCE_ROLE"), alice), "scopes must be independent");
    }

    function testRevokeRole() public {
        vm.startPrank(admin);
        rm.grantRole(sGov, alice);

        vm.expectEmit();
        emit IAccessControl.RoleRevoked(sGov, alice, admin);
        rm.revokeRole(sGov, alice);
        vm.stopPrank();
        assertFalse(rm.hasRole(sGov, alice));
    }

    function testRenounceRoleRequiresSelfConfirmation() public {
        vm.prank(admin);
        rm.grantRole(sGov, alice);

        // Confirmation must equal msg.sender.
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        vm.prank(alice);
        rm.renounceRole(sGov, bob);

        // Self-confirmation works.
        vm.expectEmit();
        emit IAccessControl.RoleRevoked(sGov, alice, alice);
        vm.prank(alice);
        rm.renounceRole(sGov, alice);
        assertFalse(rm.hasRole(sGov, alice));
    }

    function testGrantRoleIsIdempotent() public {
        vm.prank(admin);
        rm.grantRole(sGov, alice);

        // Second grant is a no-op; no event re-emitted, and state unchanged.
        vm.recordLogs();
        vm.prank(admin);
        rm.grantRole(sGov, alice);
        assertEq(vm.getRecordedLogs().length, 0, "duplicate grant must not emit");
        assertTrue(rm.hasRole(sGov, alice));
    }

    function testSetRoleAdminReorgRequiresDefaultAdmin(address rdm) public {
        vm.assume(rdm != admin);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, rdm, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(rdm);
        rm.setRoleAdmin(sCur, DEFAULT_ADMIN_ROLE);

        vm.expectEmit();
        emit IAccessControl.RoleAdminChanged(sCur, sGov, DEFAULT_ADMIN_ROLE);
        vm.prank(admin);
        rm.setRoleAdmin(sCur, DEFAULT_ADMIN_ROLE);
        assertEq(rm.getRoleAdmin(sCur), DEFAULT_ADMIN_ROLE);
    }
}
