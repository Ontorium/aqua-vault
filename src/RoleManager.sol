// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IRoleManager} from "./interfaces/IRoleManager.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @notice Minimal OZ-compatible AccessControl. Centralized role registry shared by Vault,
/// StrategyManager, strategies, and any future modules.
/// @dev Event signatures and function names match OpenZeppelin's AccessControl so indexers and
/// SDKs built for OZ work as-is.
contract RoleManager is IRoleManager {
    bytes32 public constant override DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice Top-level governance role. Holds most admin privileges across the protocol.
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    /// @notice Manages risk parameters that increase exposure (caps up, registry, etc.).
    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    /// @notice Emergency role for fast risk reductions (cap down, deallocate).
    bytes32 public constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    /// @notice Operational role for strategy allocation/deallocation.
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    mapping(bytes32 role => mapping(address account => bool)) private _roles;
    mapping(bytes32 role => bytes32 adminRole) private _roleAdmin;

    modifier onlyRole(bytes32 role) {
        require(hasRole(role, msg.sender), ErrorsLib.Unauthorized());
        _;
    }

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

    /* VIEWS */

    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return _roles[role][account];
    }

    function getRoleAdmin(bytes32 role) public view override returns (bytes32) {
        return _roleAdmin[role];
    }

    /* MUTATIONS */

    function grantRole(bytes32 role, address account) external override onlyRole(_roleAdmin[role]) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external override onlyRole(_roleAdmin[role]) {
        _revokeRole(role, account);
    }

    /// @dev `callerConfirmation` must equal msg.sender — OZ-compatible safety check.
    function renounceRole(bytes32 role, address callerConfirmation) external override {
        require(callerConfirmation == msg.sender, ErrorsLib.Unauthorized());
        _revokeRole(role, msg.sender);
    }

    /// @dev Lets the DEFAULT_ADMIN reorganize role hierarchies (e.g. give SENTINEL its own admin).
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }

    /* INTERNAL */

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal {
        bytes32 previous = _roleAdmin[role];
        _roleAdmin[role] = adminRole;
        emit RoleAdminChanged(role, previous, adminRole);
    }
}
