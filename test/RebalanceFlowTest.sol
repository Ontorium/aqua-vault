// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {RebalanceAction} from "../src/interfaces/IVault.sol";

/// @notice Exercises Vault.rebalance — the batched allocate/deallocate path that moves capital between
/// strategies. rebalance lives on the Vault itself (gated by ALLOCATOR_ROLE) and calls the internal
/// allocate/deallocate directly, so no contract needs to hold a fund-moving role. Covers the
/// strategy -> strategy move, batch atomicity, pause interaction and authorization.
contract RebalanceFlowTest is BaseTest {
    StrategyMock internal s1;
    StrategyMock internal s2;

    function setUp() public override {
        super.setUp();

        // Two strategies, caps lifted to max so the rebalance path is not blocked by cap noise.
        s1 = _addStrategyWithMaxCaps();
        s2 = _addStrategyWithMaxCaps();

        // Seed the vault with idle liquidity to rebalance from. `allocator` already holds ALLOCATOR_ROLE
        // (granted in BaseTest), which is the only role rebalance requires.
        _giveTokens(address(this), 1_000);
        underlyingToken.approve(address(vault), type(uint256).max);
        vault.deposit(1_000, address(this));
    }

    /* HELPERS */

    function _action(address strategy, bool isAllocate, uint256 assets)
        internal
        pure
        returns (RebalanceAction memory)
    {
        return RebalanceAction({strategy: strategy, isAllocate: isAllocate, assets: assets, data: hex""});
    }

    /* AUTHORIZATION */

    function testRebalanceRejectsNonAllocator(address rdm) public {
        vm.assume(rdm != allocator);

        RebalanceAction[] memory actions = new RebalanceAction[](1);
        actions[0] = _action(address(s1), true, 100);

        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vault.rebalance(actions);
    }

    /// @notice Curator and sentinel can configure caps but must NOT be able to move funds via rebalance.
    function testRebalanceRejectsCuratorAndSentinel() public {
        RebalanceAction[] memory actions = new RebalanceAction[](1);
        actions[0] = _action(address(s1), true, 100);

        vm.prank(curator);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vault.rebalance(actions);

        vm.prank(sentinel);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vault.rebalance(actions);
    }

    /* HAPPY PATHS */

    function testRebalanceAllocate() public {
        RebalanceAction[] memory actions = new RebalanceAction[](1);
        actions[0] = _action(address(s1), true, 400);

        vm.expectEmit(true, false, false, true, address(vault));
        emit EventsLib.Rebalance(allocator, 1);
        vm.prank(allocator);
        vault.rebalance(actions);

        assertEq(s1.totalAssets(), 400, "s1 funded");
        assertEq(underlyingToken.balanceOf(address(vault)), 600, "vault idle reduced");
    }

    /// @notice The core ask: move capital from one strategy to another in a single batch.
    function testRebalanceStrategyToStrategy() public {
        // Fund s1 first.
        RebalanceAction[] memory fund = new RebalanceAction[](1);
        fund[0] = _action(address(s1), true, 500);
        vm.prank(allocator);
        vault.rebalance(fund);
        assertEq(s1.totalAssets(), 500, "s1 pre-move");
        assertEq(s2.totalAssets(), 0, "s2 pre-move");

        uint256 totalBefore = vault.totalAssets();

        // Single batch: pull 500 out of s1, push it into s2.
        RebalanceAction[] memory move = new RebalanceAction[](2);
        move[0] = _action(address(s1), false, 500); // deallocate s1 -> vault
        move[1] = _action(address(s2), true, 500); // allocate vault -> s2

        vm.prank(allocator);
        vault.rebalance(move);

        assertEq(s1.totalAssets(), 0, "s1 emptied");
        assertEq(s2.totalAssets(), 500, "s2 received");
        // Funds only relocated — vault NAV unchanged.
        assertEq(vault.totalAssets(), totalBefore, "total assets conserved");
    }

    function testRebalancePartialStrategyToStrategy() public {
        RebalanceAction[] memory fund = new RebalanceAction[](1);
        fund[0] = _action(address(s1), true, 600);
        vm.prank(allocator);
        vault.rebalance(fund);

        // Move only part of s1 into s2.
        RebalanceAction[] memory move = new RebalanceAction[](2);
        move[0] = _action(address(s1), false, 250);
        move[1] = _action(address(s2), true, 250);
        vm.prank(allocator);
        vault.rebalance(move);

        assertEq(s1.totalAssets(), 350, "s1 remainder");
        assertEq(s2.totalAssets(), 250, "s2 partial");
    }

    function testRebalanceEmptyActionsIsNoop() public {
        RebalanceAction[] memory empty = new RebalanceAction[](0);

        vm.expectEmit(true, false, false, true, address(vault));
        emit EventsLib.Rebalance(allocator, 0);
        vm.prank(allocator);
        vault.rebalance(empty);
    }

    /* ATOMICITY */

    /// @notice If any action in the batch reverts, the whole batch rolls back (no partial move).
    function testRebalanceBatchIsAtomic() public {
        RebalanceAction[] memory fund = new RebalanceAction[](1);
        fund[0] = _action(address(s1), true, 500);
        vm.prank(allocator);
        vault.rebalance(fund);

        // Cap the shared id-0 at the current allocation. Both mocks report id-0/id-1, so the absolute
        // cap on id-0 governs the aggregate; a fresh 600 allocation will exceed it.
        vm.prank(sentinel);
        strategyManager.decreaseAbsoluteCap(bytes("id-0"), 500);

        // Batch: empty s1 (ok) then try to push 600 into s2 -> exceeds id-0 cap -> revert.
        RebalanceAction[] memory move = new RebalanceAction[](2);
        move[0] = _action(address(s1), false, 500);
        move[1] = _action(address(s2), true, 600);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.AbsoluteCapExceeded.selector);
        vault.rebalance(move);

        // First action rolled back too: s1 still holds its original balance.
        assertEq(s1.totalAssets(), 500, "s1 unchanged after revert");
        assertEq(s2.totalAssets(), 0, "s2 untouched after revert");
    }

    /* PAUSE INTERACTION */

    function testRebalanceAllocateBlockedWhenPaused() public {
        vm.prank(sentinel);
        vault.pause();

        RebalanceAction[] memory actions = new RebalanceAction[](1);
        actions[0] = _action(address(s1), true, 100);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.Paused.selector);
        vault.rebalance(actions);
    }

    function testRebalanceDeallocateAllowedWhenPaused() public {
        // Fund s1 before pausing.
        RebalanceAction[] memory fund = new RebalanceAction[](1);
        fund[0] = _action(address(s1), true, 300);
        vm.prank(allocator);
        vault.rebalance(fund);

        vm.prank(sentinel);
        vault.pause();

        // Deallocate is an exit path and must remain available while paused.
        RebalanceAction[] memory pull = new RebalanceAction[](1);
        pull[0] = _action(address(s1), false, 300);
        vm.prank(allocator);
        vault.rebalance(pull);

        assertEq(s1.totalAssets(), 0, "s1 drained while paused");
    }

    /// @notice A mixed batch where the allocate leg is blocked by pause reverts atomically.
    function testRebalanceMixedBatchBlockedWhenPaused() public {
        RebalanceAction[] memory fund = new RebalanceAction[](1);
        fund[0] = _action(address(s1), true, 300);
        vm.prank(allocator);
        vault.rebalance(fund);

        vm.prank(sentinel);
        vault.pause();

        // deallocate (ok while paused) then allocate (blocked) -> whole batch reverts.
        RebalanceAction[] memory move = new RebalanceAction[](2);
        move[0] = _action(address(s1), false, 300);
        move[1] = _action(address(s2), true, 300);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.Paused.selector);
        vault.rebalance(move);

        assertEq(s1.totalAssets(), 300, "s1 unchanged after paused revert");
    }
}
