// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {IReceiveAssetsGate} from "../src/interfaces/IGate.sol";

/// @notice Covers the operator-fulfilled withdrawal queue (ERC-7540 / Centrifuge style). When idle is
/// shares are escrowed and the request accumulates into a per-receiver pending slot. A request is NOT
/// claimable from liquidity alone — the ALLOCATOR must price and burn it via `fulfillWithdrawal`, moving it into
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
        emit EventsLib.WithdrawalRequested(alice, alice, alice, wantAssets, expectedShares);

        vm.prank(alice);
        uint256 sharesQueued = vault.withdraw(wantAssets, alice, alice);
        assertEq(sharesQueued, expectedShares, "queued shares match preview");

        // Shares are escrowed but remain in totalSupply; no asset liability exists until fulfillment.
        assertEq(vault.balanceOf(alice), sharesBefore - sharesQueued, "owner shares escrowed");
        assertEq(vault.balanceOf(address(vault)), sharesQueued, "vault holds escrowed shares");
        assertEq(vault.totalSupply(), sharesBefore, "escrow does not burn supply");
        assertEq(underlyingToken.balanceOf(alice), 0, "no immediate transfer");
        assertEq(vault.pendingClaimableAssets(), 0, "no asset obligation before fulfillment");
        assertFalse(vault.isClaimable(alice), "not claimable before fulfill");

        (uint128 pendingAssets, uint128 pendingShares,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingAssets), wantAssets, "pending assets");
        assertEq(uint256(pendingShares), sharesQueued, "pending shares");
    }

    /// @notice Escrowed shares are keyed by receiver and eventually paid to that receiver, not the share owner.
    function testQueuedWithdrawalUsesReceiverAsQueueIdentity() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        address receiver = makeAddr("receiver");
        uint256 wantAssets = 400e18;

        vm.expectEmit(true, true, true, true);
        emit EventsLib.WithdrawalRequested(alice, alice, receiver, wantAssets, vault.previewWithdraw(wantAssets));

        vm.prank(alice);
        vault.withdraw(wantAssets, receiver, alice);

        (uint128 receiverPending,,) = vault.pendingWithdrawal(receiver);
        (uint128 ownerPending,,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(receiverPending), wantAssets, "obligation keyed by receiver");
        assertEq(uint256(ownerPending), 0, "owner has no queued obligation");

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", wantAssets);
        _fulfill(receiver);

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        uint256 received = vault.claim(receiver);

        assertEq(received, wantAssets, "receiver claim amount");
        assertEq(underlyingToken.balanceOf(receiver), wantAssets, "receiver paid");
        assertEq(underlyingToken.balanceOf(alice), 0, "share owner not paid");
    }

    /// @notice Requests funded by different share owners merge when they name the same receiver.
    function testDifferentOwnersAccumulateForSameReceiver() public {
        address bob = makeAddr("bob");
        address receiver = makeAddr("sharedReceiver");

        _seed(500e18, 0);
        underlyingToken.mint(bob, 500e18);
        vm.startPrank(bob);
        underlyingToken.approve(address(vault), 500e18);
        vault.deposit(500e18, bob);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", 1_000e18);

        vm.prank(alice);
        vault.withdraw(200e18, receiver, alice);
        vm.prank(bob);
        vault.withdraw(300e18, receiver, bob);

        (uint128 pendingAssets,,) = vault.pendingWithdrawal(receiver);
        assertEq(uint256(pendingAssets), 500e18, "owners merge by receiver");
        assertEq(vault.pendingClaimableAssets(), 0, "no obligation before pricing");

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 500e18);
        _fulfill(receiver);
        assertEq(vault.claim(receiver), 500e18, "receiver claims merged requests");
        assertEq(underlyingToken.balanceOf(receiver), 500e18, "receiver receives aggregate");
    }

    /// @notice A receiver blacklisted after queueing cannot bypass the asset-receive gate at claim time.
    function testClaimRechecksReceiverGate() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        address receiver = makeAddr("receiver");
        address gate = makeAddr("receiveAssetsGate");
        vm.prank(governance);
        vault.setReceiveAssetsGate(gate);

        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (receiver)), abi.encode(true));
        vm.prank(alice);
        vault.withdraw(400e18, receiver, alice);

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18);
        _fulfill(receiver);

        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (receiver)), abi.encode(false));
        vm.expectRevert(ErrorsLib.CannotReceiveAssets.selector);
        vault.claim(receiver);

        assertEq(uint256(vault.claimableAssets(receiver)), 400e18, "claim remains reserved");
    }

    /// @notice Full fulfillment cannot reserve liquidity for a currently blocked receiver.
    function testFulfillRechecksReceiverGate() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        address receiver = makeAddr("receiver");
        address gate = makeAddr("receiveAssetsGate");
        vm.prank(governance);
        vault.setReceiveAssetsGate(gate);

        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (receiver)), abi.encode(true));
        vm.prank(alice);
        vault.withdraw(400e18, receiver, alice);

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18);

        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (receiver)), abi.encode(false));
        vm.expectRevert(ErrorsLib.CannotReceiveAssets.selector);
        _fulfill(receiver);

        (uint128 pendingAssets,,) = vault.pendingWithdrawal(receiver);
        assertEq(uint256(pendingAssets), 400e18, "request remains pending");
        assertEq(vault.reservedAssets(), 0, "blocked receiver reserves nothing");
        assertEq(uint256(vault.claimableAssets(receiver)), 0, "blocked receiver is not claimable");
    }

    /// @notice Partial fulfillment applies the same receiver gate as full fulfillment.
    function testPartialFulfillRechecksReceiverGate() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        address receiver = makeAddr("receiver");
        address gate = makeAddr("receiveAssetsGate");
        vm.prank(governance);
        vault.setReceiveAssetsGate(gate);

        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (receiver)), abi.encode(true));
        vm.prank(alice);
        vault.withdraw(400e18, receiver, alice);

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 200e18);

        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (receiver)), abi.encode(false));
        address[] memory receivers = new address[](1);
        receivers[0] = receiver;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200e18;

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.CannotReceiveAssets.selector);
        vault.fulfillWithdrawalPartial(receivers, amounts);

        (uint128 pendingAssets,,) = vault.pendingWithdrawal(receiver);
        assertEq(uint256(pendingAssets), 400e18, "request remains fully pending");
        assertEq(vault.reservedAssets(), 0, "blocked receiver reserves nothing");
        assertEq(uint256(vault.claimableAssets(receiver)), 0, "blocked receiver is not claimable");
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
        assertEq(vault.pendingClaimableAssets(), 0, "pending shares are not an asset obligation");
    }

    function testFulfillmentUsesHigherCurrentSharePrice() public {
        uint256 deposit = 1_000e18;
        uint256 initialShares = _seed(deposit, deposit);

        vm.prank(alice);
        vault.redeem(400e18, alice, alice);
        (, uint128 pendingShares,) = vault.pendingWithdrawal(alice);
        uint256 requestEstimate = vault.previewPendingWithdrawal(alice);

        // Add and recognize 10% strategy yield while the request remains escrowed.
        strategy.setInterest(100e18);
        underlyingToken.mint(address(strategy), 100e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();

        uint256 fulfillmentEstimate = vault.previewPendingWithdrawal(alice);
        assertGt(fulfillmentEstimate, requestEstimate, "pending request participates in yield");

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", fulfillmentEstimate);
        _fulfill(alice);

        assertEq(uint256(vault.claimableAssets(alice)), fulfillmentEstimate, "assets fixed at fulfill price");
        assertEq(vault.totalSupply(), initialShares - uint256(pendingShares), "escrow burned only at fulfill");
        assertEq(vault.previewPendingWithdrawal(alice), 0, "pending cleared after pricing");
    }

    function testFulfillmentUsesLowerCurrentSharePrice() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.prank(alice);
        vault.redeem(400e18, alice, alice);
        uint256 requestEstimate = vault.previewPendingWithdrawal(alice);

        // Recognize a 20% loss before fulfillment.
        strategy.setLoss(200e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();

        uint256 fulfillmentEstimate = vault.previewPendingWithdrawal(alice);
        assertLt(fulfillmentEstimate, requestEstimate, "pending request absorbs loss");

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", fulfillmentEstimate);
        _fulfill(alice);

        uint256 fixedAssets = vault.claimableAssets(alice);
        assertEq(fixedAssets, fulfillmentEstimate, "loss-adjusted assets fixed at fulfill");

        // Later NAV movement cannot reprice an already fulfilled claim.
        strategy.setLoss(300e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();
        assertEq(uint256(vault.claimableAssets(alice)), fixedAssets, "claimable amount remains fixed");
    }

    /// @notice All receivers in one fulfillment batch use one NAV/supply snapshot, independent of array order.
    /// forge-config: default.isolate = true
    function testBatchFulfillmentPriceIsIndependentOfReceiverOrder() public {
        address bob = makeAddr("batchBob");
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        underlyingToken.mint(bob, deposit);
        vm.startPrank(bob);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, bob);
        vm.stopPrank();
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        uint256 requestedShares = 333e18;
        vm.prank(alice);
        vault.redeem(requestedShares, alice, alice);
        vm.prank(bob);
        vault.redeem(requestedShares, bob, bob);

        strategy.setInterest(123e18);
        underlyingToken.mint(address(strategy), 123e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();

        uint256 requiredLiquidity = vault.previewPendingWithdrawal(alice) + vault.previewPendingWithdrawal(bob) + 2;
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", requiredLiquidity);

        uint256 snapshot = vm.snapshotState();
        address[] memory receivers = new address[](2);
        receivers[0] = alice;
        receivers[1] = bob;
        vm.prank(allocator);
        vault.fulfillWithdrawal(receivers);
        uint256 aliceFirst = vault.claimableAssets(alice);
        uint256 bobSecond = vault.claimableAssets(bob);

        assertTrue(vm.revertToState(snapshot), "snapshot restored");
        receivers[0] = bob;
        receivers[1] = alice;
        vm.prank(allocator);
        vault.fulfillWithdrawal(receivers);

        assertEq(uint256(vault.claimableAssets(alice)), aliceFirst, "alice independent of order");
        assertEq(uint256(vault.claimableAssets(bob)), bobSecond, "bob independent of order");
        assertEq(aliceFirst, bobSecond, "equal shares receive equal batch assets");
    }

    /// @notice A queued fee snapshot applies to the gross value determined after a NAV increase.
    /// forge-config: default.isolate = true
    function testQueuedFeeAppliesToFulfillmentPriceAfterGain() public {
        address protocolRecipient = makeAddr("gainFeeRecipient");
        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(protocolRecipient);
        vault.setWithdrawalFee(0.01e18);
        vm.stopPrank();

        _seed(1_000e18, 1_000e18);
        vm.prank(alice);
        vault.withdraw(200e18, alice, alice);

        strategy.setInterest(100e18);
        underlyingToken.mint(address(strategy), 100e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();

        (, uint128 pendingShares, uint64 feeAtRequest) = vault.pendingWithdrawal(alice);
        uint256 grossAtFulfillment = vault.convertToAssets(pendingShares);
        uint256 expectedFee = (grossAtFulfillment * uint256(feeAtRequest) + WAD - 1) / WAD;
        uint256 expectedNet = grossAtFulfillment - expectedFee;
        assertEq(vault.previewPendingWithdrawal(alice), expectedNet, "preview is fulfillment-price net");

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", grossAtFulfillment);
        _fulfill(alice);
        assertEq(vault.claim(alice), expectedNet, "claim applies snapshotted fee to new price");
        assertEq(underlyingToken.balanceOf(protocolRecipient), expectedFee, "protocol receives repriced fee");
    }

    /// @notice Requests made before and after a NAV change aggregate as shares and settle at one later price.
    /// forge-config: default.isolate = true
    function testRequestsAcrossNAVChangesAggregateAtFulfillmentPrice() public {
        _seed(1_000e18, 1_000e18);

        vm.prank(alice);
        vault.redeem(100e18, alice, alice);

        strategy.setInterest(100e18);
        underlyingToken.mint(address(strategy), 100e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();

        vm.prank(alice);
        vault.redeem(100e18, alice, alice);
        (, uint128 pendingShares,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingShares), 200e18, "requests aggregate by receiver shares");

        uint256 expectedAssets = vault.convertToAssets(pendingShares);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", expectedAssets);
        _fulfill(alice);
        assertEq(uint256(vault.claimableAssets(alice)), expectedAssets, "all shares use fulfillment price");
    }

    /// @notice forceSyncReportedNAV cannot add already-fulfilled withdrawal liabilities back into holder NAV.
    function testForceSyncDoesNotReAddFulfilledLiability() public {
        _seed(1_000e18, 1_000e18);
        vm.prank(alice);
        vault.withdraw(400e18, alice, alice);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18);
        _fulfill(alice);

        assertEq(vault.totalAssets(), 600e18, "fulfilled liability excluded before sync");
        vm.prank(governance);
        vault.forceSyncReportedNAV();
        assertEq(vault.totalAssets(), 600e18, "fulfilled liability remains excluded after sync");
    }

    /// @notice Per policy, an unfulfilled queue does not reserve liquidity or disable a fresh immediate exit.
    function testPendingQueueDoesNotBlockAnotherImmediateExit() public {
        address bob = makeAddr("immediateBob");
        _seed(500e18, 500e18);
        underlyingToken.mint(bob, 500e18);
        vm.startPrank(bob);
        underlyingToken.approve(address(vault), 500e18);
        vault.deposit(500e18, bob);
        vm.stopPrank();
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", 500e18);

        vm.prank(alice);
        vault.withdraw(200e18, alice, alice);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 100e18);

        vm.prank(bob);
        vault.withdraw(100e18, bob, bob);
        assertEq(underlyingToken.balanceOf(bob), 100e18, "available idle exits immediately");
        (, uint128 alicePendingShares,) = vault.pendingWithdrawal(alice);
        assertGt(uint256(alicePendingShares), 0, "older request remains pending");
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
        emit EventsLib.WithdrawalFulfilled(alice, wantAssets, vault.previewWithdraw(wantAssets));
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

        // Pending assets are not final yet, so the locked fee is share-weighted, NOT fixed to 0% or 2%.
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

    /// @notice Pending requests blend fees by shares because their asset values are not fixed until fulfillment.
    /// A non-unit share price makes this test fail if request aggregation silently switches back to asset weights.
    /// forge-config: default.isolate = true
    function testQueuedFeeBlendsBySharesAtNonUnitPrice() public {
        address protocolRecipient = makeAddr("nonUnitFeeRecipient");
        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(protocolRecipient);
        vault.setWithdrawalFee(0.01e18);
        vm.stopPrank();

        _seed(1_000e18, 1_000e18);

        vm.prank(alice);
        vault.redeem(100e18, alice, alice);

        strategy.setInterest(100e18);
        underlyingToken.mint(address(strategy), 100e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();

        vm.prank(governance);
        vault.setWithdrawalFee(0.03e18);
        vm.prank(alice);
        vault.redeem(200e18, alice, alice);

        (, uint128 pendingShares, uint64 lockedFee) = vault.pendingWithdrawal(alice);
        uint256 expectedLockedFee =
            (uint256(100e18) * uint256(0.01e18) + uint256(200e18) * uint256(0.03e18)) / uint256(300e18);
        assertEq(uint256(pendingShares), 300e18, "requests aggregate in shares");
        assertEq(uint256(lockedFee), expectedLockedFee, "pending fee is share-weighted");

        uint256 grossAtFulfillment = vault.convertToAssets(pendingShares);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", grossAtFulfillment);
        _fulfill(alice);

        uint256 expectedFee = (grossAtFulfillment * expectedLockedFee + WAD - 1) / WAD;
        uint256 aliceBefore = underlyingToken.balanceOf(alice);
        assertEq(vault.claim(alice), grossAtFulfillment - expectedFee, "claim applies blended fee to final assets");
        assertEq(underlyingToken.balanceOf(alice) - aliceBefore, grossAtFulfillment - expectedFee, "receiver gets net");
        assertEq(underlyingToken.balanceOf(protocolRecipient), expectedFee, "protocol gets blended fee");
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

    /// @notice The partial-fulfillment input is denominated in shares, not assets. At a 1.1 price,
    /// fulfilling 300 shares fixes roughly 330 assets while reducing the pending request by 300 shares.
    /// forge-config: default.isolate = true
    function testPartialFulfillUsesSharesAtNonUnitPrice() public {
        _seed(1_000e18, 1_000e18);

        vm.prank(alice);
        vault.redeem(600e18, alice, alice);
        (uint128 estimatedAssetsBefore, uint128 pendingSharesBefore,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(pendingSharesBefore), 600e18, "600 shares queued");

        strategy.setInterest(100e18);
        underlyingToken.mint(address(strategy), 100e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();

        uint256 sharesToSettle = 300e18;
        uint256 expectedClaimable = vault.convertToAssets(sharesToSettle);
        assertApproxEqAbs(expectedClaimable, 330e18, 1, "300 shares worth about 330 assets");

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", expectedClaimable);

        address[] memory receivers = new address[](1);
        uint256[] memory shares = new uint256[](1);
        receivers[0] = alice;
        shares[0] = sharesToSettle;
        vm.prank(allocator);
        vault.fulfillWithdrawalPartial(receivers, shares);

        (uint128 estimatedAssetsAfter, uint128 pendingSharesAfter,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(vault.claimableAssets(alice)), expectedClaimable, "shares convert at settlement price");
        assertEq(uint256(pendingSharesAfter), 300e18, "remaining request reduced by shares");
        assertEq(
            uint256(estimatedAssetsAfter),
            uint256(estimatedAssetsBefore) / 2,
            "request-time asset estimate reduced pro rata"
        );
        assertApproxEqAbs(
            vault.previewPendingWithdrawal(alice),
            vault.convertToAssets(pendingSharesAfter),
            1,
            "remaining shares retain current-price estimate"
        );
    }

    /// @notice Escrowing and later burning Alice's proportional shares must not transfer value to or from Bob.
    /// NAV gains may change Bob's value, but request, fulfillment, and claim introduce no additional repricing.
    /// forge-config: default.isolate = true
    function testNonWithdrawingHolderValueInvariantAcrossQueueLifecycle() public {
        address bob = makeAddr("passiveBob");
        uint256 deposit = 500e18;
        uint256 aliceShares = _seed(deposit, deposit);

        underlyingToken.mint(bob, deposit);
        vm.startPrank(bob);
        underlyingToken.approve(address(vault), deposit);
        uint256 bobShares = vault.deposit(deposit, bob);
        vm.stopPrank();
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        uint256 bobValueBeforeRequest = vault.convertToAssets(bobShares);
        vm.prank(alice);
        vault.redeem(aliceShares * 2 / 5, alice, alice);
        assertApproxEqAbs(
            vault.convertToAssets(bobShares), bobValueBeforeRequest, 1, "request does not reprice passive holder"
        );

        strategy.setInterest(100e18);
        underlyingToken.mint(address(strategy), 100e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();
        uint256 bobValueBeforeFulfill = vault.convertToAssets(bobShares);
        assertGt(bobValueBeforeFulfill, bobValueBeforeRequest, "only strategy gain changes Bob value");

        uint256 aliceSettlementAssets = vault.previewPendingWithdrawal(alice);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", aliceSettlementAssets);
        assertApproxEqAbs(
            vault.convertToAssets(bobShares), bobValueBeforeFulfill, 1, "deallocation does not reprice passive holder"
        );

        _fulfill(alice);
        assertApproxEqAbs(
            vault.convertToAssets(bobShares), bobValueBeforeFulfill, 1, "fulfillment preserves passive holder value"
        );

        vault.claim(alice);
        assertApproxEqAbs(
            vault.convertToAssets(bobShares), bobValueBeforeFulfill, 1, "claim preserves passive holder value"
        );
    }

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
        emit EventsLib.WithdrawalFulfilled(alice, 300e18, 300e18);
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

    /// @notice Claimable fee aggregation is asset-weighted when partial fills occur at different NAVs.
    /// Pending fee aggregation remains share-weighted until each tranche receives its final asset value.
    /// forge-config: default.isolate = true
    function testPartialFulfillsAtDifferentPricesBlendClaimableFeeByAssets() public {
        address protocolRecipient = makeAddr("partialFeeRecipient");
        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(protocolRecipient);
        vault.setWithdrawalFee(0.01e18);
        vm.stopPrank();

        _seed(1_000e18, 1_000e18);
        vm.prank(alice);
        vault.redeem(200e18, alice, alice);

        address[] memory receivers = new address[](1);
        uint256[] memory shares = new uint256[](1);
        receivers[0] = alice;
        shares[0] = 100e18;

        uint256 firstGross = vault.convertToAssets(shares[0]);
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", firstGross);
        vm.prank(allocator);
        vault.fulfillWithdrawalPartial(receivers, shares);
        assertEq(uint256(vault.claimableFee(alice)), 0.01e18, "first tranche keeps 1% fee");

        vm.prank(governance);
        vault.setWithdrawalFee(0.03e18);
        vm.prank(alice);
        vault.redeem(100e18, alice, alice);
        (,, uint64 secondPendingFee) = vault.pendingWithdrawal(alice);
        assertEq(uint256(secondPendingFee), 0.02e18, "remaining 1% and new 3% shares blend to 2%");

        strategy.setInterest(100e18);
        underlyingToken.mint(address(strategy), 100e18);
        vm.prank(governance);
        vault.forceSyncReportedNAV();

        uint256 secondGross = vault.convertToAssets(shares[0]);
        assertGt(secondGross, firstGross, "second tranche settles at higher NAV");
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", secondGross);
        vm.prank(allocator);
        vault.fulfillWithdrawalPartial(receivers, shares);

        uint256 totalGross = firstGross + secondGross;
        uint256 expectedClaimableFee =
            (firstGross * 0.01e18 + secondGross * uint256(secondPendingFee)) / totalGross;
        assertEq(uint256(vault.claimableAssets(alice)), totalGross, "claimable assets accumulate by tranche value");
        assertEq(uint256(vault.claimableFee(alice)), expectedClaimableFee, "claimable fee is asset-weighted");

        uint256 expectedFee = (totalGross * expectedClaimableFee + WAD - 1) / WAD;
        assertEq(vault.claim(alice), totalGross - expectedFee, "claim pays net accumulated assets");
        assertEq(underlyingToken.balanceOf(protocolRecipient), expectedFee, "protocol receives accumulated fee");

        (, uint128 remainingShares,) = vault.pendingWithdrawal(alice);
        assertEq(uint256(remainingShares), 100e18, "unfulfilled shares remain pending");
    }

    /// @notice Three users queue different amounts. After the operator fulfills all of them, each user can
    /// claim ONLY the assets reserved for their own request — not more, not another user's reservation.
    /// Verifies per-user accounting isolation across many simultaneous pending entries.
    function testMultiplePendingUsersClaimOnlyOwnAllocation() public {
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        // Each deposits a distinct amount and the allocator drains all idle into the strategy so every
        // withdraw is forced into the pending queue.
        _seed(500e18, 500e18); // alice
        for (uint256 i; i < 2; ++i) {
            (address who, uint256 amt) = i == 0 ? (bob, 300e18) : (carol, 200e18);
            underlyingToken.mint(who, amt);
            vm.startPrank(who);
            underlyingToken.approve(address(vault), amt);
            vault.deposit(amt, who);
            vm.stopPrank();
            vm.prank(allocator);
            vault.allocate(address(strategy), hex"", amt);
        }

        // Distinct withdraw requests: alice 250, bob 180, carol 150.
        vm.prank(alice);
        vault.withdraw(250e18, alice, alice);
        vm.prank(bob);
        vault.withdraw(180e18, bob, bob);
        vm.prank(carol);
        vault.withdraw(150e18, carol, carol);

        // Bring back exactly enough idle and fulfill all three in one operator call.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 250e18 + 180e18 + 150e18);
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        vm.prank(allocator);
        vault.fulfillWithdrawal(users);

        // Each user's claimable reflects only their own request.
        assertEq(uint256(vault.claimableAssets(alice)), 250e18, "alice reserved");
        assertEq(uint256(vault.claimableAssets(bob)), 180e18, "bob reserved");
        assertEq(uint256(vault.claimableAssets(carol)), 150e18, "carol reserved");
        assertEq(vault.reservedAssets(), 580e18, "total reserved = sum of all three");

        // Each claim pays out exactly that user's own allocation — no cross-contamination.
        assertEq(vault.claim(alice), 250e18, "alice gets her own");
        assertEq(underlyingToken.balanceOf(alice), 250e18);
        assertEq(vault.claim(bob), 180e18, "bob gets his own");
        assertEq(underlyingToken.balanceOf(bob), 180e18);
        assertEq(vault.claim(carol), 150e18, "carol gets her own");
        assertEq(underlyingToken.balanceOf(carol), 150e18);

        // Nothing left reserved; nobody can double-claim.
        assertEq(vault.reservedAssets(), 0, "all reservations released");
        vm.expectRevert(ErrorsLib.RequestNotPending.selector);
        vault.claim(alice);
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
