// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {AccessControl} from "./vendor/AccessControl.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @notice Centralized role registry shared by Vault, StrategyManager, strategies, and any future
/// modules (they delegate their role checks here via AccessManaged). 
contract RoleManager is AccessControl {
    /// @notice Top-level governance role. Holds most admin privileges across the protocol.
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    /// @notice Manages risk parameters that increase exposure (caps up, registry, etc.).
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    /// @notice Emergency role for fast risk reductions (cap down, deallocate).
    bytes32 public constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    /// @notice Operational role for strategy allocation/deallocation.
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    constructor(address admin) {
        require(admin != address(0), ErrorsLib.ZeroAddress());

        // DEFAULT_ADMIN_ROLE is self-administered (admins manage themselves).
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        // GOVERNANCE inherits from DEFAULT_ADMIN, others inherit from GOVERNANCE.
        _setRoleAdmin(GOVERNANCE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(CURATOR_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(SENTINEL_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(ALLOCATOR_ROLE, GOVERNANCE_ROLE);
    }

    /// @dev Lets the DEFAULT_ADMIN reorganize role hierarchies (e.g. give SENTINEL its own admin).
    /// Kept from the original RoleManager API; {AccessControl} only exposes the internal `_setRoleAdmin`.
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }
}
