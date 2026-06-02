// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {AccessControl} from "./vendor/AccessControl.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/// @notice Shared role registry for vaults and their modules.
/// @dev Roles are namespaced by scope so one deployment can manage many vaults independently.
contract RoleManager is AccessControl {
    /// @notice Base governance role for a scope.
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    /// @notice Role for risk configuration.
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    /// @notice Role for emergency actions.
    bytes32 public constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    /// @notice Role for strategy operations.
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    /// @notice True once a scope has been registered.
    mapping(address scope => bool) public isScopeRegistered;

    constructor(address admin) {
        require(admin != address(0), ErrorsLib.ZeroAddress());

        // DEFAULT_ADMIN_ROLE remains the global admin role.
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Returns the scoped role id for `roleName`.
    function getScopedRole(address scope, string calldata roleName) external pure returns (bytes32) {
        return _scoped(scope, keccak256(bytes(roleName)));
    }

    /// @dev Returns a scoped role id from a hashed base role.
    function _scoped(address scope, bytes32 baseRole) internal pure returns (bytes32) {
        return keccak256(abi.encode(scope, baseRole));
    }

    /// @notice Registers a scope and wires its governance hierarchy.
    /// @dev Does not grant membership and is safe to call more than once.
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

    /// @dev Exposes `_setRoleAdmin` to the global admin.
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }
}
