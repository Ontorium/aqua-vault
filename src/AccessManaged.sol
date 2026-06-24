// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IAccessControl} from "./interfaces/IAccessControl.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @notice Base contract for modules that delegate role checks to a shared RoleManager.
/// @dev Core roles are scoped by `roleScope`, typically the vault address.
abstract contract AccessManaged {
    /// @dev Unscoped base role names. Effective role ids are derived with `_scoped`.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 internal constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 internal constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    IAccessControl public immutable roleManager;

    /// @dev Scope used for core role checks.
    address public immutable roleScope;

    constructor(address _roleManager, address _roleScope) {
        require(_roleManager != address(0), ErrorsLib.ZeroAddress());
        require(_roleScope != address(0), ErrorsLib.ZeroAddress());
        roleManager = IAccessControl(_roleManager);
        roleScope = _roleScope;
    }

    /// @dev Returns the scoped role id for a base role.
    function _scoped(bytes32 baseRole) internal view returns (bytes32) {
        return keccak256(abi.encode(roleScope, baseRole));
    }

    modifier onlyRole(bytes32 role) {
        require(roleManager.hasRole(_scoped(role), msg.sender), ErrorsLib.Unauthorized());
        _;
    }

    /// @dev Requires either of the two roles.
    function _requireAnyRole(bytes32 role1, bytes32 role2) internal view {
        require(
            roleManager.hasRole(_scoped(role1), msg.sender) || roleManager.hasRole(_scoped(role2), msg.sender),
            ErrorsLib.Unauthorized()
        );
    }

    /// @dev Requires at least one of the three roles.
    function _requireAnyRole(bytes32 role1, bytes32 role2, bytes32 role3) internal view {
        require(
            roleManager.hasRole(_scoped(role1), msg.sender) || roleManager.hasRole(_scoped(role2), msg.sender)
                || roleManager.hasRole(_scoped(role3), msg.sender),
            ErrorsLib.Unauthorized()
        );
    }

    /// @dev Returns a role id scoped to this contract instance.
    function _scopedRole(bytes32 roleName) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), roleName));
    }
}
