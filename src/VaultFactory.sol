// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.28;

import {Vault} from "./Vault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";

contract VaultFactory is IVaultFactory {
    mapping(address account => bool) public isVault;
    mapping(address owner => mapping(address asset => mapping(bytes32 salt => address))) public vault;

    /// @dev Returns the address of the deployed Vault.
    function createVault(address owner, address asset, bytes32 salt) external returns (address) {
        address newVault = address(new Vault{salt: salt}(owner, asset));

        isVault[newVault] = true;
        vault[owner][asset][salt] = newVault;
        emit CreateVault(owner, asset, salt, newVault);

        return newVault;
    }
}
