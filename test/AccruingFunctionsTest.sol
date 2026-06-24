// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract AccruingFunctionsTest is BaseTest {
    StrategyMock strategy;

    function setUp() public override {
        super.setUp();

        strategy = _addStrategyWithMaxCaps();

        // Seed the vault with a single unit and a single allocation so allocate/deallocate work for `0` touches.
        underlyingToken.mint(address(vault), 1);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", 1);
    }

    function testAllocateAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", 0);
    }

    function testForceDeallocateAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vault.forceDeallocate(address(strategy), hex"", 0, address(this));
    }

    function testDepositAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vault.deposit(0, address(this));
    }

    function testMintAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vault.mint(0, address(this));
    }

    function testWithdrawAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vault.withdraw(0, address(this), address(this));
    }

    function testRedeemAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vault.redeem(0, address(this), address(this));
    }

    function testSetPerformanceFeeAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vm.prank(governance);
        vault.setPerformanceFee(0);
    }

    function testSetManagementFeeAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vm.prank(governance);
        vault.setManagementFee(0);
    }

    function testSetPerformanceFeeRecipientAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vm.prank(governance);
        vault.setPerformanceFeeRecipient(address(0));
    }

    function testSetManagementFeeRecipientAccruesInterest() public {
        skip(1);
        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vm.prank(governance);
        vault.setManagementFeeRecipient(address(0));
    }

    function testSetMaxRateAccruesInterest() public {
        skip(1);
        vm.prank(governance);
        vault.setMaxRate(MAX_MAX_RATE);
        assertEq(vault.lastUpdate(), block.timestamp);
    }
}
