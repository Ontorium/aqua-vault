// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity >=0.5.0;

interface IVaultFactory {
    /* EVENTS */

    event CreateVault(
        address indexed owner,
        address indexed asset,
        bytes32 salt,
        address indexed newVault,
        address roleManager
    );

    /* FUNCTIONS */

    function isVault(address account) external view returns (bool);
    function vault(address owner, address asset, bytes32 salt) external view returns (address);
    function createVault(address roleManager, address owner, address asset, bytes32 salt)
        external
        returns (address newVault);
}
