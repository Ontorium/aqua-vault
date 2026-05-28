// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

/// @notice Covers the Centrifuge-style per-user pending withdrawal queue: when idle is insufficient,
/// shares are burned and the request accumulates into a single slot keyed by `onBehalf`. The slot is
/// cleared (`delete` → gas refund) on claim/cancel.
contract WithdrawalQueueTest is BaseTest {
    address internal immutable alice = makeAddr("alice");
    StrategyMock internal strategy;

    function setUp() public override {
        super.setUp();
        strategy = _addStrategyWithMaxCaps();
    }

    /// @dev Seeds the vault with `deposit` from alice and pushes `allocated` to the strategy.
    function _seed(uint256 deposit, uint256 allocated) internal returns (uint256 shares) {
        underlyingToken.mint(alice, deposit);
        vm.startPrank(alice);
        underlyingToken.approve(address(vault), deposit);
        shares = vault.deposit(deposit, alice);
        vm.stopPrank();

        if (allocated > 0) {
            vm.prank(allocator);
            vault.allocate(address(strategy), hex"", allocated);
        }
    }

    function testQueuesWhenIdleInsufficient() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit); // drain idle completely

        uint256 wantAssets = 400e18;
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 expectedShares = vault.previewWithdraw(wantAssets);

        vm.expectEmit(true, true, false, true);
        emit EventsLib.WithdrawalRequested(alice, alice, wantAssets, expectedShares);

        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(wantAssets, alice, alice);
        assertEq(sharesBurned, expectedShares, "burned matches preview");

        // Shares burned, no immediate transfer.
        assertEq(vault.balanceOf(alice), sharesBefore - sharesBurned, "shares burned");
        assertEq(underlyingToken.balanceOf(alice), 0, "no immediate transfer");
        assertEq(vault.pendingClaimableAssets(), wantAssets, "earmark recorded");

        (uint128 pendingAssets, uint128 pendingShares) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingAssets), wantAssets, "pending assets");
        assertEq(uint256(pendingShares), sharesBurned, "pending shares");
    }

    /// @notice Two sequential withdraws by the same user collapse into one slot — the second
    /// pays only the warm-update cost (~5k gas), not a fresh ~20k cold SSTORE.
    function testSequentialWithdrawsAccumulateIntoOneSlot() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.startPrank(alice);
        uint256 shares1 = vault.withdraw(200e18, alice, alice);
        uint256 shares2 = vault.withdraw(300e18, alice, alice);
        vm.stopPrank();

        (uint128 pendingAssets, uint128 pendingShares) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingAssets), 500e18, "aggregated assets");
        assertEq(uint256(pendingShares), shares1 + shares2, "aggregated shares");
        assertEq(vault.pendingClaimableAssets(), 500e18, "earmark sums");
    }

    function testIsClaimableFlipsWithLiquidity() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        uint256 wantAssets = 400e18;
        vm.prank(alice);
        vault.withdraw(wantAssets, alice, alice);

        assertFalse(vault.isClaimable(alice), "no idle yet");

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", wantAssets);

        assertTrue(vault.isClaimable(alice), "liquid now");
    }

    function testClaimSettlesPendingAndClearsSlot() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        uint256 wantAssets = 400e18;
        vm.prank(alice);
        vault.withdraw(wantAssets, alice, alice);

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", wantAssets);

        // Permissionless: anyone may trigger; assets always flow to onBehalf.
        address anyone = makeAddr("anyone");
        vm.expectEmit(true, false, false, true);
        emit EventsLib.WithdrawalClaimed(alice, wantAssets);
        vm.prank(anyone);
        uint256 received = vault.claim(alice);

        assertEq(received, wantAssets, "no withdrawal fee");
        assertEq(underlyingToken.balanceOf(alice), wantAssets, "alice paid out");
        assertEq(vault.pendingClaimableAssets(), 0, "earmark released");

        // Slot cleared: subsequent reads see zero, re-claim reverts.
        (uint128 pa, uint128 ps) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pa), 0, "slot cleared (assets)");
        assertEq(uint256(ps), 0, "slot cleared (shares)");

        vm.expectRevert(ErrorsLib.RequestNotPending.selector);
        vault.claim(alice);
    }

    function testClaimFailsWithoutLiquidity() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.prank(alice);
        vault.withdraw(400e18, alice, alice);

        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        vault.claim(alice);
    }

    function testWithdrawalFeeAppliedAtClaimTime() public {
        address protocolRecipient = makeAddr("protocolRecipient");
        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(protocolRecipient);
        vault.setWithdrawalFee(0.01e18);
        vm.stopPrank();

        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        uint256 netWanted = 396e18;
        vm.prank(alice);
        vault.withdraw(netWanted, alice, alice);

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18);

        vault.claim(alice);

        assertEq(underlyingToken.balanceOf(alice), netWanted, "alice net");
        assertEq(underlyingToken.balanceOf(protocolRecipient), 4e18, "1% fee routed");
    }

    /// @notice Documents the design choice: per-user accumulation means each user has an independent
    /// slot. `isClaimable(user)` is purely a `balance >= my_assets` check — there is no FIFO across
    /// users, and a later requester can claim before an earlier one as long as their own amount fits
    /// current idle. Race ordering is determined by who calls `claim` first, not by request order.
    function testDifferentUsersHaveIndependentSlots() public {
        address bob = makeAddr("bob");

        // alice deposits and queues.
        _seed(500e18, 500e18);
        vm.prank(alice);
        vault.withdraw(200e18, alice, alice);

        // bob deposits and queues.
        underlyingToken.mint(bob, 500e18);
        vm.startPrank(bob);
        underlyingToken.approve(address(vault), 500e18);
        vault.deposit(500e18, bob);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", 500e18);

        vm.prank(bob);
        vault.withdraw(300e18, bob, bob);

        // Two distinct slots.
        (uint128 alicePending,) = vault.pendingWithdrawal(alice);
        (uint128 bobPending,) = vault.pendingWithdrawal(bob);
        assertEq(uint256(alicePending), 200e18);
        assertEq(uint256(bobPending), 300e18);

        // Bring back exactly bob's amount. With balance=300, both alice(200) and bob(300) are
        // *technically* claimable since each check is `balance >= my_assets` independently — but only
        // one will succeed (whoever calls first drains the idle).
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 300e18);

        assertTrue(vault.isClaimable(alice), "alice claimable (200 <= 300)");
        assertTrue(vault.isClaimable(bob), "bob claimable (300 <= 300)");

        // Bob wins the race.
        vault.claim(bob);
        assertEq(underlyingToken.balanceOf(bob), 300e18, "bob received");
        // Now vault.balance = 0; alice is stuck until more liquidity returns.
        assertFalse(vault.isClaimable(alice), "alice no longer claimable");
        (uint128 aliceAfter,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(aliceAfter), 200e18, "alice slot untouched");
    }
}
