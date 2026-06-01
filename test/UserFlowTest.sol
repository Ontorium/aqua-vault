// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

/// @notice End-to-end coverage for the user-side lifecycle in §7.3 of the design:
/// approve → deposit (mint shares) → allocate → accrue interest → redeem on the immediate path,
/// then the same shape with a strategy fully drained so withdrawals queue up.
contract UserFlowTest is BaseTest {
    address internal immutable alice = makeAddr("alice");
    address internal immutable bob = makeAddr("bob");

    StrategyMock internal strategy;

    function setUp() public override {
        super.setUp();

        vm.prank(governance);
        vault.setMaxRate(MAX_MAX_RATE);

        strategy = _addStrategyWithMaxCaps();
    }

    /// @notice Walks every step in §7.3 with profit, then redeems on the immediate path.
    /// @dev Isolated so each external call lands in its own tx and `firstTotalAssets` (transient) resets
    /// between deposit → allocate → setInterest → totalAssets reads.
    /// forge-config: default.isolate = true
    function testFullLifecycleWithInterestImmediateExit() public {
        uint256 deposit = 1_000e18;
        uint256 interest = 50e18;

        // Step 1-2: Alice approves and deposits.
        underlyingToken.mint(alice, deposit);
        vm.startPrank(alice);
        underlyingToken.approve(address(vault), deposit);
        uint256 shares = vault.deposit(deposit, alice);
        vm.stopPrank();

        // Step 3: Vault minted shares 1:1 (no prior supply).
        assertEq(shares, deposit * vault.virtualShares(), "shares minted at 1:1");
        assertEq(vault.balanceOf(alice), shares, "alice has shares");
        assertEq(underlyingToken.balanceOf(address(vault)), deposit, "vault holds principal");

        // Step 4: Allocator routes the whole principal into the strategy.
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);
        assertEq(underlyingToken.balanceOf(address(vault)), 0);
        assertEq(underlyingToken.balanceOf(address(strategy)), deposit);
        assertEq(strategyManager.totalStrategyAssets(), deposit);

        // Step 5: Strategy reports interest. Vault.totalAssets() picks it up (subject to maxRate clamp).
        strategy.setInterest(interest);
        skip(365 days); // give maxRate room to amortise the interest
        uint256 expectedTotal = deposit + interest;
        assertApproxEqAbs(vault.totalAssets(), expectedTotal, 1, "interest reflected in totalAssets");

        // Step 7-8: Alice redeems half her shares. Strategy gets touched via forceDeallocate-style flow first.
        // To exit on the immediate path, return some liquidity to the Vault.
        uint256 redeemShares = shares / 2;
        // Deallocate enough underlying to fund the immediate redeem.
        uint256 expectedAssets = vault.previewRedeem(redeemShares);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", expectedAssets);

        vm.prank(alice);
        uint256 outAssets = vault.redeem(redeemShares, alice, alice);

        assertEq(outAssets, expectedAssets, "redeemed amount");
        assertEq(underlyingToken.balanceOf(alice), expectedAssets, "alice received assets");
        assertEq(vault.balanceOf(alice), shares - redeemShares, "alice's remaining shares");
        // Withdrawal queue stayed empty — immediate path was used.
        (uint128 pending,,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pending), 0, "no queue entries");
    }

    /// @notice §7.3 user pulls all idle and the rest gets queued.
    function testRedeemSplitImmediateAndQueued() public {
        uint256 deposit = 1_000e18;
        uint256 keepIdle = 200e18; // stays in vault for immediate path
        uint256 allocatedAmount = deposit - keepIdle;

        underlyingToken.mint(alice, deposit);
        vm.startPrank(alice);
        underlyingToken.approve(address(vault), deposit);
        uint256 shares = vault.deposit(deposit, alice);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", allocatedAmount);
        assertEq(underlyingToken.balanceOf(address(vault)), keepIdle, "idle = keepIdle");

        // First withdraw fits in idle — immediate path.
        vm.prank(alice);
        uint256 sharesBurned1 = vault.withdraw(keepIdle, alice, alice);
        assertGt(sharesBurned1, 0);
        assertEq(underlyingToken.balanceOf(alice), keepIdle, "immediate transfer landed");

        // Second withdraw exceeds idle (which is now 0) — queues.
        uint256 wantQueued = 100e18;
        vm.prank(alice);
        uint256 sharesBurned2 = vault.withdraw(wantQueued, alice, alice);
        assertGt(sharesBurned2, 0);
        // alice's balance hasn't moved (still keepIdle from before).
        assertEq(underlyingToken.balanceOf(alice), keepIdle);
        (uint128 pendingAssets,,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingAssets), wantQueued, "one queued request aggregated");
        assertEq(vault.pendingClaimableAssets(), wantQueued, "queued amount tracked");

        // Shares burned in both paths.
        assertEq(vault.balanceOf(alice), shares - sharesBurned1 - sharesBurned2);
    }

    /// @notice Two users deposit at different times, second user's share price reflects accrued interest.
    /// forge-config: default.isolate = true
    function testTwoUsersFairSharePricing() public {
        uint256 aliceDeposit = 500e18;
        uint256 bobDeposit = 500e18;
        uint256 interest = 100e18;

        // Alice deposits first.
        underlyingToken.mint(alice, aliceDeposit);
        vm.startPrank(alice);
        underlyingToken.approve(address(vault), aliceDeposit);
        uint256 aliceShares = vault.deposit(aliceDeposit, alice);
        vm.stopPrank();

        // Allocate Alice's principal to the strategy and accrue some interest.
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", aliceDeposit);
        strategy.setInterest(interest);
        skip(365 days);

        // Bob deposits after interest accrual. He must receive fewer shares per asset than Alice did.
        underlyingToken.mint(bob, bobDeposit);
        vm.startPrank(bob);
        underlyingToken.approve(address(vault), bobDeposit);
        uint256 bobShares = vault.deposit(bobDeposit, bob);
        vm.stopPrank();

        assertLt(bobShares, aliceShares, "bob receives fewer shares at higher share price");

        // Alice's claim on assets must be larger than her deposit (gains earned), Bob's claim ≈ his deposit.
        uint256 aliceClaim = vault.convertToAssets(aliceShares);
        uint256 bobClaim = vault.convertToAssets(bobShares);
        assertGt(aliceClaim, aliceDeposit, "alice profited");
        assertApproxEqRel(bobClaim, bobDeposit, 0.005e18, "bob's claim approx deposit at entry");
    }

    /// @notice Sanity check on §7.3 step 5 covering the loss case: totalAssets must drop.
    /// forge-config: default.isolate = true
    function testLossReducesTotalAssets() public {
        uint256 deposit = 1_000e18;
        uint256 loss = 100e18;

        underlyingToken.mint(alice, deposit);
        vm.startPrank(alice);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        strategy.setLoss(loss);
        vault.accrueInterest();

        assertEq(vault.totalAssets(), deposit - loss, "loss realised on accrual");
    }
}
