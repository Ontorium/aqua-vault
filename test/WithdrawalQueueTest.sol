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

        (uint128 pendingAssets, uint128 pendingShares) = vault.pendingWithdrawal(alice);
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

        (uint128 pendingAssets, uint128 pendingShares) = vault.pendingWithdrawal(alice);
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
        (uint128 pa,) = vault.pendingWithdrawal(alice);
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
}
