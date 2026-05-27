// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {WithdrawalStatus} from "../src/interfaces/IVault.sol";

/// @notice Focused coverage for the queued withdrawal path: when idle is insufficient, the user's
/// shares are burned, an entry is recorded, and anyone may `claim` once liquidity returns.
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

        vm.expectEmit(true, true, true, false);
        emit EventsLib.WithdrawalRequested(0, alice, alice, alice, wantAssets, 0);

        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(wantAssets, alice, alice);

        // Shares burned, assets not yet transferred.
        assertEq(vault.balanceOf(alice), sharesBefore - sharesBurned, "shares burned");
        assertEq(underlyingToken.balanceOf(alice), 0, "no immediate transfer");
        assertEq(vault.nextRequestId(), 1, "request created");
        assertEq(vault.pendingClaimableAssets(), wantAssets, "earmark recorded");

        // Request stored with Pending status, correct owners.
        (address onBehalf, , WithdrawalStatus status, address receiver, uint128 assets, uint128 reqShares) =
            vault.withdrawalRequests(0);
        assertEq(onBehalf, alice);
        assertEq(receiver, alice);
        assertEq(uint8(status), uint8(WithdrawalStatus.Pending));
        assertEq(uint256(assets), wantAssets);
        assertEq(uint256(reqShares), sharesBurned);
    }

    function testIsClaimableFlipsWithLiquidity() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        uint256 wantAssets = 400e18;
        vm.prank(alice);
        vault.withdraw(wantAssets, alice, alice);

        assertFalse(vault.isClaimable(0), "no idle yet");

        // Allocator pulls assets back from the strategy.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", wantAssets);

        assertTrue(vault.isClaimable(0), "liquid now");
    }

    function testClaimSettlesPendingRequest() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        uint256 wantAssets = 400e18;
        vm.prank(alice);
        vault.withdraw(wantAssets, alice, alice);

        // Bring liquidity back.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", wantAssets);

        // Anyone may execute the claim — assets flow to the stored receiver.
        address randomCaller = makeAddr("anyone");
        vm.expectEmit(true, true, false, true);
        emit EventsLib.WithdrawalClaimed(0, alice, wantAssets);
        vm.prank(randomCaller);
        uint256 received = vault.claim(0);

        assertEq(received, wantAssets, "no withdrawal fee");
        assertEq(underlyingToken.balanceOf(alice), wantAssets, "alice paid out");
        assertEq(vault.pendingClaimableAssets(), 0, "earmark released");

        ( , , WithdrawalStatus status, , , ) = vault.withdrawalRequests(0);
        assertEq(uint8(status), uint8(WithdrawalStatus.Claimed));

        // Re-claim must revert.
        vm.expectRevert(ErrorsLib.RequestNotPending.selector);
        vault.claim(0);
    }

    function testClaimFailsWithoutLiquidity() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.prank(alice);
        vault.withdraw(400e18, alice, alice);

        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        vault.claim(0);
    }

    function testCancelWithdrawalRestoresShares() public {
        uint256 deposit = 1_000e18;
        uint256 sharesIssued = _seed(deposit, deposit);

        uint256 wantAssets = 400e18;
        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(wantAssets, alice, alice);

        // Only the original onBehalf may cancel.
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(makeAddr("randomCanceler"));
        vault.cancelWithdrawal(0);

        vm.expectEmit(true, true, false, true);
        emit EventsLib.WithdrawalCancelled(0, alice, sharesBurned, wantAssets);
        vm.prank(alice);
        uint256 restored = vault.cancelWithdrawal(0);

        assertEq(restored, sharesBurned, "shares restored");
        assertEq(vault.balanceOf(alice), sharesIssued, "balance back to original");
        assertEq(vault.pendingClaimableAssets(), 0, "earmark released");

        ( , , WithdrawalStatus status, , , ) = vault.withdrawalRequests(0);
        assertEq(uint8(status), uint8(WithdrawalStatus.Cancelled));

        // A cancelled request cannot be claimed.
        vm.expectRevert(ErrorsLib.RequestNotPending.selector);
        vault.claim(0);
    }

    function testWithdrawalFeeAppliedAtClaimTime() public {
        // Wire up a protocol fee recipient and a 1% withdrawal fee.
        address protocolRecipient = makeAddr("protocolRecipient");
        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(protocolRecipient);
        vault.setWithdrawalFee(0.01e18);
        vm.stopPrank();

        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        // alice asks for net 396 (with 1% fee, grossAssets = 400).
        uint256 netWanted = 396e18;
        vm.prank(alice);
        vault.withdraw(netWanted, alice, alice);

        // Top up vault so claim succeeds.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 400e18);

        vault.claim(0);

        // alice receives net, protocol recipient receives the fee.
        assertEq(underlyingToken.balanceOf(alice), netWanted, "alice net");
        assertEq(underlyingToken.balanceOf(protocolRecipient), 4e18, "1% fee routed");
    }

    function testMultipleQueuedRequestsServedInOrder() public {
        uint256 deposit = 1_000e18;
        _seed(deposit, deposit);

        vm.startPrank(alice);
        vault.withdraw(200e18, alice, alice); // id 0
        vault.withdraw(300e18, alice, alice); // id 1
        vm.stopPrank();

        assertEq(vault.nextRequestId(), 2);
        assertEq(vault.pendingClaimableAssets(), 500e18, "earmark = sum");

        // Bring 200 back; only request 0 becomes claimable.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 200e18);
        assertTrue(vault.isClaimable(0));
        assertFalse(vault.isClaimable(1));

        vault.claim(0);
        assertEq(underlyingToken.balanceOf(alice), 200e18);
        assertEq(vault.pendingClaimableAssets(), 300e18);

        // Bring the rest back and claim request 1.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", 300e18);
        vault.claim(1);
        assertEq(underlyingToken.balanceOf(alice), 500e18);
        assertEq(vault.pendingClaimableAssets(), 0);
    }
}
