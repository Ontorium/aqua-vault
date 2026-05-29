// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {AccessControl} from "./vendor/AccessControl.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/// @notice Centralized, single-deployment role registry shared by every vault (and their StrategyManager,
/// strategies, Timelock, and any future modules, which delegate role checks here via AccessManaged).
/// @dev Roles are namespaced per scope: the role id checked is `getScopedRole(scope, roleName)` where `scope`
/// is the vault address (or the Timelock's own address for its governance crew). One RoleManager therefore
/// manages permissions for many vaults independently. Per-scope hierarchy is established by {registerScope}:
///   - DEFAULT_ADMIN_ROLE (global): protocol super-admin, administers every scope's GOVERNANCE.
///   - scoped(scope, GOVERNANCE): administers that scope's CURATOR/SENTINEL/ALLOCATOR.
contract RoleManager is AccessControl {
    /// @notice Base role names. The effective role id is `getScopedRole(scope, <NAME>)`, never the bare hash.
    /// @notice Top-level governance role. Holds most admin privileges within a scope.
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    /// @notice Manages risk parameters that increase exposure (caps up, registry, etc.).
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    /// @notice Emergency role for fast risk reductions (cap down, deallocate).
    bytes32 public constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    /// @notice Operational role for strategy allocation/deallocation.
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    /// @notice True once {registerScope} has wired a scope's GOVERNANCE→operational admin hierarchy.
    mapping(address scope => bool) public isScopeRegistered;

    constructor(address admin) {
        require(admin != address(0), ErrorsLib.ZeroAddress());

        // DEFAULT_ADMIN_ROLE is self-administered (admins manage themselves) and is the global super-admin.
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Vault-scoped role id from a human-readable role NAME. A single function covers every role —
    /// the four core ones AND any module-specific role (e.g. "OFFCHAIN_REPORTER", "NAV_UPDATER") or any
    /// added later — with no per-role helper. Produces the exact id AccessManaged checks at runtime:
    /// `keccak256(abi.encode(scope, keccak256(bytes(roleName))))`.
    function getScopedRole(address scope, string calldata roleName) external pure returns (bytes32) {
        return _scoped(scope, keccak256(bytes(roleName)));
    }

    /// @dev Namespaces an already-hashed base role under `scope`. Mirrors AccessManaged's `_scoped`.
    function _scoped(address scope, bytes32 baseRole) internal pure returns (bytes32) {
        return keccak256(abi.encode(scope, baseRole));
    }

    /// @notice Establishes the per-scope role hierarchy: the scope's GOVERNANCE administers its CURATOR/
    /// SENTINEL/ALLOCATOR, while GOVERNANCE itself stays administered by the global DEFAULT_ADMIN (its default).
    /// @dev Deterministic and grants NO membership, so it is safe to call permissionlessly (the VaultFactory
    /// calls it for each new vault). Idempotent — a second call for the same scope is a no-op.
    function registerScope(address scope) external {
        require(scope != address(0), ErrorsLib.ZeroAddress());
        if (isScopeRegistered[scope]) return;
        isScopeRegistered[scope] = true;

        bytes32 gov = _scoped(scope, GOVERNANCE_ROLE);
        _setRoleAdmin(_scoped(scope, CURATOR_ROLE), gov);
        _setRoleAdmin(_scoped(scope, SENTINEL_ROLE), gov);
        _setRoleAdmin(_scoped(scope, ALLOCATOR_ROLE), gov);

        emit EventsLib.RegisterScope(scope);
    }

    /// @dev Lets the DEFAULT_ADMIN reorganize role hierarchies (e.g. give a scope's SENTINEL its own admin).
    /// Kept from the original RoleManager API; {AccessControl} only exposes the internal `_setRoleAdmin`.
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }
}
