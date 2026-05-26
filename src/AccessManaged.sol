// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IRoleManager} from "./interfaces/IRoleManager.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @notice Abstract base for any contract that delegates permission checks to a central RoleManager.
/// @dev Inherit and use `onlyRole(role)` for single-role gating, or `_requireAnyRole` for OR logic.
abstract contract AccessManaged {
    /// @dev Mirrors of RoleManager's well-known role constants. Hashes are deterministic, so these
    /// are guaranteed identical to RoleManager's, no cross-contract read required.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 internal constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 internal constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    IRoleManager public immutable roleManager;

    constructor(address _roleManager) {
        require(_roleManager != address(0), ErrorsLib.ZeroAddress());
        roleManager = IRoleManager(_roleManager);
    }

    modifier onlyRole(bytes32 role) {
        require(roleManager.hasRole(role, msg.sender), ErrorsLib.Unauthorized());
        _;
    }

    /// @dev Convenience for "user has at least one of these two roles".
    function _requireAnyRole(bytes32 role1, bytes32 role2) internal view {
        require(
            roleManager.hasRole(role1, msg.sender) || roleManager.hasRole(role2, msg.sender),
            ErrorsLib.Unauthorized()
        );
    }

    /// @dev Convenience for "user has at least one of these three roles".
    function _requireAnyRole(bytes32 role1, bytes32 role2, bytes32 role3) internal view {
        require(
            roleManager.hasRole(role1, msg.sender)
                || roleManager.hasRole(role2, msg.sender)
                || roleManager.hasRole(role3, msg.sender),
            ErrorsLib.Unauthorized()
        );
    }

    /// @dev Per-instance scoped role hash. Each contract instance has a unique role per name.
    /// Use this when the same logical role (e.g. "REPORTER") must be distinct per strategy/instance.
    function _scopedRole(bytes32 roleName) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), roleName));
    }
}
