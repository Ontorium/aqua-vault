// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {IStrategyManager} from "../src/interfaces/IStrategyManager.sol";

contract StrategyManagerTest is BaseTest {
    StrategyMock internal strategy;

    function setUp() public override {
        super.setUp();
        strategy = new StrategyMock(address(vault), address(underlyingToken));
    }

    function testWiringFromFactory() public view {
        assertEq(strategyManager.vault(), address(vault));
        assertEq(strategyManager.asset(), address(underlyingToken));
        assertEq(strategyManager.strategyRegistry(), address(0));
        assertEq(strategyManager.strategiesLength(), 0);
    }

    function testAddStrategyRequiresGovernance(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        strategyManager.addStrategy(address(strategy), 1, 0);
    }

    function testAddStrategy() public {
        vm.expectEmit();
        emit EventsLib.AddStrategy(address(strategy));
        vm.prank(governance);
        strategyManager.addStrategy(address(strategy), 1, 200);

        assertTrue(strategyManager.isStrategy(address(strategy)));
        assertTrue(strategyManager.isStrategyActive(address(strategy)));
        assertEq(strategyManager.strategiesLength(), 1);
        assertEq(strategyManager.strategies(0), address(strategy));

        IStrategyManager.StrategyInfo memory info = strategyManager.strategyInfo(address(strategy));
        assertEq(info.strategy, address(strategy));
        assertTrue(info.config.active);
        assertEq(info.config.targetBps, 200);
        assertEq(info.config.kind, 1);
    }

    function testAddStrategyRejectsZero() public {
        vm.prank(governance);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        strategyManager.addStrategy(address(0), 1, 0);
    }

    function testRemoveStrategy() public {
        vm.prank(governance);
        strategyManager.addStrategy(address(strategy), 1, 0);

        vm.expectEmit();
        emit EventsLib.RemoveStrategy(address(strategy));
        vm.prank(governance);
        strategyManager.removeStrategy(address(strategy));

        assertFalse(strategyManager.isStrategy(address(strategy)));
        assertEq(strategyManager.strategiesLength(), 0);
    }

    function testRemoveStrategyBlockedWhenAllocated() public {
        vm.prank(governance);
        strategyManager.addStrategy(address(strategy), 1, 0);

        // Simulate a residual allocation by directly minting tokens to the strategy and bumping its books.
        underlyingToken.mint(address(strategy), 1);
        // Use vault.allocate path to set _principal so totalAssets() > 0.
        // First lift caps so allocate succeeds.
        vm.startPrank(governance);
        strategyManager.increaseAbsoluteCap(bytes("id-0"), type(uint128).max);
        strategyManager.increaseAbsoluteCap(bytes("id-1"), type(uint128).max);
        strategyManager.increaseRelativeCap(bytes("id-0"), WAD);
        strategyManager.increaseRelativeCap(bytes("id-1"), WAD);
        vm.stopPrank();

        underlyingToken.mint(address(vault), 100);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", 100);

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.ZeroAllocation.selector);
        strategyManager.removeStrategy(address(strategy));
    }

    function testSetStrategyActive() public {
        vm.startPrank(governance);
        strategyManager.addStrategy(address(strategy), 1, 0);

        vm.expectEmit();
        emit EventsLib.SetStrategyActive(address(strategy), false);
        strategyManager.setStrategyActive(address(strategy), false);
        assertFalse(strategyManager.isStrategyActive(address(strategy)));

        strategyManager.setStrategyActive(address(strategy), true);
        assertTrue(strategyManager.isStrategyActive(address(strategy)));
        vm.stopPrank();
    }

    function testIncreaseAbsoluteCapMonotonic(uint256 a, uint256 b) public {
        a = bound(a, 1, type(uint128).max - 1);
        b = bound(b, 0, a - 1);

        bytes memory idData = bytes("id-0");
        bytes32 id = keccak256(idData);

        vm.prank(governance);
        strategyManager.increaseAbsoluteCap(idData, a);
        assertEq(strategyManager.absoluteCap(id), a);

        // Cannot increase to a strictly smaller value.
        vm.prank(governance);
        vm.expectRevert(ErrorsLib.AbsoluteCapNotIncreasing.selector);
        strategyManager.increaseAbsoluteCap(idData, b);
    }

    function testDecreaseAbsoluteCapBySentinel(uint256 a, uint256 b) public {
        a = bound(a, 1, type(uint128).max);
        b = bound(b, 0, a);

        bytes memory idData = bytes("id-0");
        bytes32 id = keccak256(idData);

        vm.prank(governance);
        strategyManager.increaseAbsoluteCap(idData, a);

        vm.prank(sentinel);
        strategyManager.decreaseAbsoluteCap(idData, b);
        assertEq(strategyManager.absoluteCap(id), b);
    }

    function testIncreaseRelativeCapBoundedByWad(uint256 r) public {
        r = bound(r, WAD + 1, type(uint128).max);

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.RelativeCapAboveOne.selector);
        strategyManager.increaseRelativeCap(bytes("id-0"), r);
    }

    function testSetForceDeallocatePenalty(uint256 penalty) public {
        penalty = bound(penalty, 0, MAX_FORCE_DEALLOCATE_PENALTY);

        vm.prank(governance);
        strategyManager.addStrategy(address(strategy), 1, 0);

        vm.prank(governance);
        vm.expectEmit();
        emit EventsLib.SetForceDeallocatePenalty(address(strategy), penalty);
        strategyManager.setForceDeallocatePenalty(address(strategy), penalty);
        assertEq(strategyManager.forceDeallocatePenalty(address(strategy)), penalty);
    }

    function testOnAllocateOnlyVault(address rdm) public {
        vm.assume(rdm != address(vault));
        bytes32[] memory ids = new bytes32[](0);
        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        strategyManager.onAllocate(address(strategy), ids, 0, 0);
    }

    function testTotalStrategyAssetsAggregates() public {
        StrategyMock s1 = new StrategyMock(address(vault), address(underlyingToken));
        StrategyMock s2 = new StrategyMock(address(vault), address(underlyingToken));

        vm.startPrank(governance);
        strategyManager.addStrategy(address(s1), 1, 0);
        strategyManager.addStrategy(address(s2), 1, 0);
        strategyManager.increaseAbsoluteCap(bytes("id-0"), type(uint128).max);
        strategyManager.increaseAbsoluteCap(bytes("id-1"), type(uint128).max);
        strategyManager.increaseRelativeCap(bytes("id-0"), WAD);
        strategyManager.increaseRelativeCap(bytes("id-1"), WAD);
        vm.stopPrank();

        underlyingToken.mint(address(vault), 300);
        vm.startPrank(allocator);
        vault.allocate(address(s1), hex"", 100);
        vault.allocate(address(s2), hex"", 200);
        vm.stopPrank();

        assertEq(strategyManager.totalStrategyAssets(), 300);
    }
}
