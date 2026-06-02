// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

/// @notice Covers the operator-fulfilled withdrawal queue (ERC-7540 / Centrifuge style). When idle is
/// insufficient, shares are burned and the request accumulates into a per-user pending slot. A request is NOT
/// claimable from liquidity alone — the ALLOCATOR must `fulfillWithdrawal`, which moves it into the user's
/// reserved `claimableAssets` and locks the backing liquidity. `claim` then pays out the reserved amount, so a
/// fulfilled request can never be jumped by another user.
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

    function _fulfill(address user) internal {
        address[] memory users = new address[](1);
        users[0] = user;
        vm.prank(allocator);
        vault.fulfillWithdrawal(users);
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

        // Shares burned, no immediate transfer, not yet claimable (operator must fulfill).
        assertEq(vault.balanceOf(alice), sharesBefore - sharesBurned, "shares burned");
        assertEq(underlyingToken.balanceOf(alice), 0, "no immediate transfer");
        assertEq(vault.pendingClaimableAssets(), wantAssets, "obligation recorded");
        assertFalse(vault.isClaimable(alice), "not claimable before fulfill");

        (uint128 pendingAssets, uint128 pendingShares,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingAssets), wantAssets, "pending assets");
        assertEq(uint256(pendingShares), sharesBurned, "pending shares");
    }

    /// @notice Two sequential withdraws by the same user collapse into one slot.
    function testSequentialWithdrawsAccumulateIntoOneSlot() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.startPrank(alice);
        uint256 shares1 = vault.withdraw(200e18, alice, alice);
        uint256 shares2 = vault.withdraw(300e18, alice, alice);
        vm.stopPrank();

        (uint128 pendingAssets, uint128 pendingShares,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingAssets), 500e18, "aggregated assets");
        assertEq(uint256(pendingShares), shares1 + shares2, "aggregated shares");
        assertEq(vault.pendingClaimableAssets(), 500e18, "obligation sums");
    }

    /// @notice Liquidity alone does NOT make a request claimable — only the operator's fulfill does.
    function testIsClaimableOnlyAfterFulfill() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        uint256 wantAssets = 400e18;
        vm.prank(alice);
        vault.withdraw(wantAssets, alice, alice);
        assertFalse(vault.isClaimable(alice), "no liquidity, not fulfilled");

        // Liquidity returns, but that alone is not enough.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", wantAssets);
        assertFalse(vault.isClaimable(alice), "liquidity alone is insufficient");

        // Operator fulfills -> reserved for alice -> claimable.
        vm.expectEmit(true, false, false, true);
        emit EventsLib.WithdrawalFulfilled(alice, wantAssets);
        _fulfill(alice);

        assertTrue(vault.isClaimable(alice), "claimable after fulfill");
        assertEq(uint256(vault.claimableAssets(alice)), wantAssets, "reserved for alice");
        assertEq(vault.reservedAssets(), wantAssets, "reserved pool");
        (uint128 pa,,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pa), 0, "pending moved into reserved by fulfill");
    }

    function testClaimSettlesAfterFulfill() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        uint256 wantAssets = 400e18;
        vm.prank(alice);
        vault.withdraw(wantAssets, alice, alice);

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", wantAssets);
        _fulfill(alice);

        // Permissionless: anyone may trigger; assets always flow to onBehalf.
        address anyone = makeAddr("anyone");
        vm.expectEmit(true, false, false, true);
        emit EventsLib.WithdrawalClaimed(alice, wantAssets);
        vm.prank(anyone);
        uint256 received = vault.claim(alice);

        assertEq(received, wantAssets, "no withdrawal fee");
        assertEq(underlyingToken.balanceOf(alice), wantAssets, "alice paid out");
        assertEq(uint256(vault.claimableAssets(alice)), 0, "claim cleared");
        assertEq(vault.reservedAssets(), 0, "reserved released");
        assertEq(vault.pendingClaimableAssets(), 0, "obligation cleared");

        // Re-claim reverts (nothing reserved).
        vm.expectRevert(ErrorsLib.RequestNotPending.selector);
        vault.claim(alice);
    }

    /// @notice Claim reverts until the operator fulfills — even when the vault already holds the liquidity.
    function testClaimRevertsBeforeFulfill() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.prank(alice);
        vault.withdraw(400e18, alice, alice);

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18);

        vm.expectRevert(ErrorsLib.RequestNotPending.selector);
        vault.claim(alice);
    }

    /// @notice Fulfill reverts when unreserved idle cannot cover the request.
    function testFulfillRevertsWithoutLiquidity() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit); // idle drained

        vm.prank(alice);
        vault.withdraw(400e18, alice, alice);

        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        vault.fulfillWithdrawal(users);
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
        _fulfill(alice);

        vault.claim(alice);

        assertEq(underlyingToken.balanceOf(alice), netWanted, "alice net");
        assertEq(underlyingToken.balanceOf(protocolRecipient), 4e18, "1% fee routed");
    }

    /// @notice Fee is snapshotted at queue entry: a governance fee change AFTER the user queues must not
    /// affect their claim payout. Protects queued users from fee policy shifts during their wait.
    function testWithdrawalFeeSnapshottedAtRequest() public {
        address protocolRecipient = makeAddr("protocolRecipient");
        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(protocolRecipient);
        vault.setWithdrawalFee(0.01e18); // 1% at request time
        vm.stopPrank();

        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        // Alice queues at 1%.
        uint256 netWanted = 396e18;
        vm.prank(alice);
        vault.withdraw(netWanted, alice, alice);

        // Governance jacks fee to 5% AFTER alice is in the queue.
        vm.prank(governance);
        vault.setWithdrawalFee(0.05e18);

        // Fulfill and claim — alice must still pay the 1% she queued at, not 5%.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18);
        _fulfill(alice);
        vault.claim(alice);

        assertEq(underlyingToken.balanceOf(alice), netWanted, "alice received locked-fee net");
        assertEq(underlyingToken.balanceOf(protocolRecipient), 4e18, "1% fee at request, not 5%");
    }

    /// @notice Two queued requests at different fee rates merge with a weighted average. Verifies that the
    /// snapshotted fee tracks across accumulating submissions, not just the first.
    function testQueuedFeeIsWeightedAverageAcrossSubmissions() public {
        address protocolRecipient = makeAddr("protocolRecipient");
        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(protocolRecipient);
        vault.setWithdrawalFee(0); // start at 0 — first submission locks 0
        vm.stopPrank();

        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        // First request at 0% fee for 200 underlying.
        vm.prank(alice);
        vault.withdraw(200e18, alice, alice);

        // Governance raises to 2%.
        vm.prank(governance);
        vault.setWithdrawalFee(0.02e18);

        // Second request at 2% for 200 more (net asked).
        // gross = ceil(200 / 0.98) ≈ 204.0816...e18 → +4.0816e18 fee weight
        vm.prank(alice);
        vault.withdraw(200e18, alice, alice);

        // Locked fee should be the asset-weighted average of 0% and 2%, NOT 0 nor 2%.
        (uint128 pendingAssets,, uint64 lockedFee) = vault.pendingWithdrawal(alice);
        assertGt(uint256(lockedFee), 0, "locked fee should reflect the 2% submission");
        assertLt(uint256(lockedFee), 0.02e18, "locked fee should be below the latest 2%");
        // sanity: assets accumulated
        assertGt(uint256(pendingAssets), 400e18, "gross accumulated (>= 400 because of 2% gross-up)");

        // Bring liquidity back and fulfill+claim. Locked fee carries through to claimableFee.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", uint256(pendingAssets));
        _fulfill(alice);
        assertEq(uint256(vault.claimableFee(alice)), uint256(lockedFee), "claimableFee mirrors locked");
        vault.claim(alice);

        // Protocol should have received the fee implied by the locked rate, not the current rate.
        uint256 expectedFee = (uint256(pendingAssets) * uint256(lockedFee) + 1e18 - 1) / 1e18; // mulDivUp
        assertEq(underlyingToken.balanceOf(protocolRecipient), expectedFee, "fee = stored_gross * lockedFee");
    }

    /// @notice The operator controls fulfillment order and reserved funds cannot be jumped: once alice is
    /// fulfilled, bob can neither claim nor drain alice's reserved liquidity, and bob is only claimable once
    /// the operator fulfills him too (which needs unreserved liquidity).
    function testOperatorControlsOrderNoJumping() public {
        address bob = makeAddr("bob");

        // alice deposits 500, allocates 500, queues 200.
        _seed(500e18, 500e18);
        vm.prank(alice);
        vault.withdraw(200e18, alice, alice);

        // bob deposits 500, allocates 500, queues 300.
        underlyingToken.mint(bob, 500e18);
        vm.startPrank(bob);
        underlyingToken.approve(address(vault), 500e18);
        vault.deposit(500e18, bob);
        vm.stopPrank();
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", 500e18);
        vm.prank(bob);
        vault.withdraw(300e18, bob, bob);

        // Bring back 300 idle. Neither is claimable yet (not fulfilled).
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 300e18);
        assertFalse(vault.isClaimable(alice));
        assertFalse(vault.isClaimable(bob));

        // Operator fulfills ALICE first (controls order).
        _fulfill(alice);
        assertTrue(vault.isClaimable(alice), "alice reserved");
        assertFalse(vault.isClaimable(bob), "bob not fulfilled");
        assertEq(vault.reservedAssets(), 200e18);

        // Bob cannot claim, and cannot take alice's reserved funds.
        vm.expectRevert(ErrorsLib.RequestNotPending.selector);
        vault.claim(bob);

        // Free idle now 300 - 200(reserved) = 100 < 300 -> bob cannot be fulfilled yet.
        address[] memory u = new address[](1);
        u[0] = bob;
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        vault.fulfillWithdrawal(u);

        // Alice claims her reserved 200.
        vault.claim(alice);
        assertEq(underlyingToken.balanceOf(alice), 200e18, "alice received");
        assertEq(vault.reservedAssets(), 0, "alice reservation released");

        // Bring back more, then fulfill + claim bob.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 200e18); // idle back to 300
        _fulfill(bob);
        vault.claim(bob);
        assertEq(underlyingToken.balanceOf(bob), 300e18, "bob received");
    }

    /// @notice Liquidity reserved for a fulfilled withdrawal cannot be pushed back into a strategy.
    function testReservedFundsNotAllocatable() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.prank(alice);
        vault.withdraw(400e18, alice, alice);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18); // idle 400
        _fulfill(alice); // reserves all 400

        // idle balance is 400 but fully reserved for alice -> nothing free to allocate.
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        vault.allocate(address(strategy), hex"", 1);
    }

    /* ── PARTIAL FULFILL ──────────────────────────────────────────────────────── */

    /// @notice Partial fulfill: alice requests 1000, operator moves only 300 to claimable. The remaining
    /// 700 stays in pendingWithdrawal with shares reduced proportionally.
    function testPartialFulfillSplitsPendingAndClaimable() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        // alice queues 1000.
        vm.prank(alice);
        vault.withdraw(1_000e18, alice, alice);
        (uint128 pendingBefore, uint128 sharesBefore,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingBefore), 1_000e18, "queued gross");

        // Operator brings back enough liquidity for a partial fulfill of 300.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 300e18);

        address[] memory users = new address[](1);
        uint256[] memory amts = new uint256[](1);
        users[0] = alice;
        amts[0] = 300e18;

        vm.expectEmit(true, false, false, true);
        emit EventsLib.WithdrawalFulfilled(alice, 300e18);
        vm.prank(allocator);
        vault.fulfillWithdrawalPartial(users, amts);

        // Pending shrank by 300, shares shrank proportionally (300/1000 = 30%).
        (uint128 pendingAfter, uint128 sharesAfter,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingAfter), 700e18, "remaining pending");
        // floor(sharesBefore * 700 / 1000)
        uint256 expectedSharesAfter = uint256(sharesBefore) * 700e18 / 1_000e18;
        assertEq(uint256(sharesAfter), expectedSharesAfter, "shares proportional");

        // Claimable now reflects the 300 partial.
        assertEq(uint256(vault.claimableAssets(alice)), 300e18, "claimable = partial");
        assertEq(vault.reservedAssets(), 300e18, "reservation matches");
        assertTrue(vault.isClaimable(alice));

        // alice claims the partial amount; the other 700 stays queued.
        vault.claim(alice);
        assertEq(underlyingToken.balanceOf(alice), 300e18, "alice paid partial");
        (uint128 stillPending,,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(stillPending), 700e18, "rest still queued");
    }

    /// @notice Partial fulfill across multiple users with different amounts in a single call.
    function testPartialFulfillMultipleUsers() public {
        address bob = makeAddr("bob");
        uint256 deposit = 1_000e18;

        // Both seed and queue.
        _seed(deposit, deposit);
        underlyingToken.mint(bob, deposit);
        vm.startPrank(bob);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, bob);
        vm.stopPrank();
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        vm.prank(alice);
        vault.withdraw(1_000e18, alice, alice);
        vm.prank(bob);
        vault.withdraw(200e18, bob, bob);

        // Bring back 600 idle, operator fulfills alice 500 + bob 100.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 600e18);

        address[] memory users = new address[](2);
        uint256[] memory amts = new uint256[](2);
        users[0] = alice; users[1] = bob;
        amts[0] = 500e18; amts[1] = 100e18;
        vm.prank(allocator);
        vault.fulfillWithdrawalPartial(users, amts);

        // Both users have partial claimable, partial pending.
        assertEq(uint256(vault.claimableAssets(alice)), 500e18);
        assertEq(uint256(vault.claimableAssets(bob)), 100e18);
        (uint128 alicePending,,) = vault.pendingWithdrawal(alice);
        (uint128 bobPending,,) = vault.pendingWithdrawal(bob);
        assertEq(uint256(alicePending), 500e18, "alice 500 left");
        assertEq(uint256(bobPending), 100e18, "bob 100 left");
        assertEq(vault.reservedAssets(), 600e18, "total reserved");
    }

    /// @notice Partial fulfill that drains the user's pending to exactly 0 deletes the storage slot
    /// (same observable state as the full-fulfill path).
    function testPartialFulfillDrainingDeletesEntry() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.prank(alice);
        vault.withdraw(400e18, alice, alice);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18);

        address[] memory users = new address[](1);
        uint256[] memory amts = new uint256[](1);
        users[0] = alice;
        amts[0] = 400e18;   // full pending amount via partial path
        vm.prank(allocator);
        vault.fulfillWithdrawalPartial(users, amts);

        (uint128 pendingAfter, uint128 sharesAfter,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingAfter), 0, "drained");
        assertEq(uint256(sharesAfter), 0, "shares cleared");
    }

    function testPartialFulfillRevertsOnAmountExceedingPending() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.prank(alice);
        vault.withdraw(200e18, alice, alice);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 500e18);

        address[] memory users = new address[](1);
        uint256[] memory amts = new uint256[](1);
        users[0] = alice;
        amts[0] = 300e18; // > pending 200

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InvalidRequest.selector);
        vault.fulfillWithdrawalPartial(users, amts);
    }

    function testPartialFulfillRevertsOnLengthMismatch() public {
        address[] memory users = new address[](2);
        uint256[] memory amts = new uint256[](1);
        users[0] = alice;
        users[1] = makeAddr("bob");
        amts[0] = 100;

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InvalidRequest.selector);
        vault.fulfillWithdrawalPartial(users, amts);
    }

    function testPartialFulfillRevertsOnInsufficientLiquidity() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit); // idle drained

        vm.prank(alice);
        vault.withdraw(400e18, alice, alice);

        address[] memory users = new address[](1);
        uint256[] memory amts = new uint256[](1);
        users[0] = alice;
        amts[0] = 100e18;

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        vault.fulfillWithdrawalPartial(users, amts);
    }

    /// @notice Multiple partial fulfills on the same user accumulate into a single claimable balance.
    /// Common in RWA flows where custodian liquidity arrives in successive batches.
    function testPartialFulfillAccumulatesAcrossCalls() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.prank(alice);
        vault.withdraw(1_000e18, alice, alice);

        // First batch: 400 lands.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18);
        address[] memory u = new address[](1);
        uint256[] memory a = new uint256[](1);
        u[0] = alice; a[0] = 400e18;
        vm.prank(allocator);
        vault.fulfillWithdrawalPartial(u, a);
        assertEq(uint256(vault.claimableAssets(alice)), 400e18, "first batch claimable");

        // Second batch: 300 lands, accumulates into claimable.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 300e18);
        a[0] = 300e18;
        vm.prank(allocator);
        vault.fulfillWithdrawalPartial(u, a);
        assertEq(uint256(vault.claimableAssets(alice)), 700e18, "claimable accumulated");

        // Pending still has 300 remaining.
        (uint128 stillPending,,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(stillPending), 300e18, "300 left pending");

        // Alice claims the accumulated 700 in one shot.
        vault.claim(alice);
        assertEq(underlyingToken.balanceOf(alice), 700e18, "received accumulated");
    }

    /// @notice Empty-array call is a no-op (length matches, loop runs 0 times). Useful as a
    /// permissioned heartbeat / scheduler default.
    function testPartialFulfillEmptyArraysIsNoop() public {
        address[] memory users = new address[](0);
        uint256[] memory amts = new uint256[](0);

        vm.prank(allocator);
        vault.fulfillWithdrawalPartial(users, amts);
        // No state changes — nothing to assert beyond non-revert.
    }
}
