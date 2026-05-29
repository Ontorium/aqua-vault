// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IAccessControl} from "./interfaces/IAccessControl.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @notice Abstract base for any contract that delegates permission checks to a central RoleManager.
/// @dev Inherit and use `onlyRole(role)` for single-role gating, or `_requireAnyRole` for OR logic.
/// @dev A single shared RoleManager serves many vaults. Core roles (GOVERNANCE/CURATOR/SENTINEL/
/// ALLOCATOR) are namespaced under `roleScope` (the vault address) so each vault's permissions are
/// managed independently. Vault and Timelock are their own scope; a vault's satellites (StrategyManager,
/// PriceManager, OffchainNAVStrategy) share the vault's scope.
abstract contract AccessManaged {
    /// @dev Mirrors of RoleManager's well-known base role names. Hashes are deterministic, so these
    /// are guaranteed identical to RoleManager's, no cross-contract read required. These are the
    /// UNSCOPED base names; the actual role id checked is `keccak256(abi.encode(roleScope, baseRole))`.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 internal constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 internal constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    IAccessControl public immutable roleManager;

    /// @dev The scope (vault address) that core role checks are namespaced under. Binds this contract's
    /// permissions to one vault inside the shared RoleManager. Must match RoleManager.getScopedRole(...).
    address public immutable roleScope;

    constructor(address _roleManager, address _roleScope) {
        require(_roleManager != address(0), ErrorsLib.ZeroAddress());
        require(_roleScope != address(0), ErrorsLib.ZeroAddress());
        roleManager = IAccessControl(_roleManager);
        roleScope = _roleScope;
    }

    /// @dev Resolves a base role name to its vault-scoped role id.
    function _scoped(bytes32 baseRole) internal view returns (bytes32) {
        return keccak256(abi.encode(roleScope, baseRole));
    }

    modifier onlyRole(bytes32 role) {
        require(roleManager.hasRole(_scoped(role), msg.sender), ErrorsLib.Unauthorized());
        _;
    }

    /// @dev Convenience for "user has at least one of these two roles".
    function _requireAnyRole(bytes32 role1, bytes32 role2) internal view {
        require(
            roleManager.hasRole(_scoped(role1), msg.sender) || roleManager.hasRole(_scoped(role2), msg.sender),
            ErrorsLib.Unauthorized()
        );
    }

    /// @dev Convenience for "user has at least one of these three roles".
    function _requireAnyRole(bytes32 role1, bytes32 role2, bytes32 role3) internal view {
        require(
            roleManager.hasRole(_scoped(role1), msg.sender)
                || roleManager.hasRole(_scoped(role2), msg.sender)
                || roleManager.hasRole(_scoped(role3), msg.sender),
            ErrorsLib.Unauthorized()
        );
    }

    /// @dev Per-instance scoped role hash, keyed by `address(this)` (NOT `roleScope`). Use this for
    /// roles that must stay distinct per contract instance even when instances share a vault scope —
    /// e.g. a per-strategy "REPORTER" or a per-PriceManager "NAV_UPDATER".
    function _scopedRole(bytes32 roleName) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), roleName));
    }
}
