// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract MulticallTest is BaseTest {
    function testMulticallBatchesGovernanceSetters() public {
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(Vault.setName, ("aqua"));
        data[1] = abi.encodeCall(Vault.setSymbol, ("AQA"));

        vm.prank(governance);
        vault.multicall(data);

        assertEq(vault.name(), "aqua");
        assertEq(vault.symbol(), "AQA");
    }

    function testMulticallRevertsIfAnyCallFails() public {
        address rdm = makeAddr("rdm");

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(Vault.setName, ("aqua"));
        data[1] = abi.encodeCall(Vault.setSymbol, ("AQA"));

        // rdm has no governance role - the entire batch must revert.
        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vault.multicall(data);

        // State unchanged.
        assertEq(vault.name(), "");
        assertEq(vault.symbol(), "");
    }

    function testMulticallEmpty() public {
        vm.prank(governance);
        vault.multicall(new bytes[](0));
    }
}
