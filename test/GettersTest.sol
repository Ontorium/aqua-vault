// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract GettersTest is BaseTest {
    function testDomainSeparator(uint64 chainId) public {
        vm.chainId(chainId);
        bytes32 expected = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(vault)));
        assertEq(vault.DOMAIN_SEPARATOR(), expected);
    }

    function testDecimalsScale(uint8 dec) public {
        dec = uint8(bound(uint256(dec), 0, 36));
        ERC20Mock token = new ERC20Mock(dec);
        (address newVault,) = vaultFactory.createVault(owner, address(token), keccak256(abi.encode(dec)));
        uint256 expectedDecimals = dec >= 18 ? dec : 18;
        assertEq(Vault(newVault).decimals(), expectedDecimals);
    }

    function testVirtualShares(uint8 dec) public {
        dec = uint8(bound(uint256(dec), 0, 36));
        ERC20Mock token = new ERC20Mock(dec);
        (address newVault,) = vaultFactory.createVault(owner, address(token), keccak256(abi.encode(dec)));
        uint256 expectedVirtualShares = dec >= 18 ? 1 : 10 ** (18 - dec);
        assertEq(Vault(newVault).virtualShares(), expectedVirtualShares);
    }

    function testInitialState() public view {
        // Assets in the vault start empty.
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.asset(), address(underlyingToken));
        assertEq(vault.lastUpdate(), block.timestamp);
        assertEq(vault.maxRate(), 0);

        // No gates and no priceManager wired by default.
        assertEq(vault.receiveSharesGate(), address(0));
        assertEq(vault.sendSharesGate(), address(0));
        assertEq(vault.receiveAssetsGate(), address(0));
        assertEq(vault.sendAssetsGate(), address(0));
        assertEq(vault.priceManager(), address(0));

        // Fees default to zero.
        assertEq(vault.performanceFee(), 0);
        assertEq(vault.managementFee(), 0);
        assertEq(vault.depositFee(), 0);
        assertEq(vault.withdrawalFee(), 0);
    }
}
