// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {IReceiveSharesGate} from "../src/interfaces/IGate.sol";

/// @notice Adversarial scenarios: inflation attacks, share-price manipulation, griefing surface,
/// pause asymmetry, reentrancy via gates, and pending-withdrawal price locking.
contract SecurityTest is BaseTest {
    address internal immutable attacker = makeAddr("attacker");
    address internal immutable victim = makeAddr("victim");

    StrategyMock internal strategy;

    function setUp() public override {
        super.setUp();
        strategy = _addStrategyWithMaxCaps();
    }

    /* ── INFLATION ATTACK ─────────────────────────────────────────────────────── */

    /// @notice First-depositor inflation attack: attacker deposits 1 wei then donates a huge amount
    /// hoping subsequent users get rounded-to-zero shares.
    /// @dev The combination of `virtualShares` + the `+1` in the denominator + the `maxRate` clamp
    /// makes the attack uneconomical: with maxRate=0 the donation is invisible, and with maxRate>0
    /// the inflation amortises over time so the attacker cannot suddenly spike share price.
    /// forge-config: default.isolate = true
    function testInflationAttackVictimGetsNonZeroShares() public {
        vm.prank(governance);
        vault.setMaxRate(MAX_MAX_RATE);

        // 1) attacker deposits 1 wei.
        underlyingToken.mint(attacker, 1);
        vm.startPrank(attacker);
        underlyingToken.approve(address(vault), 1);
        uint256 attackerShares = vault.deposit(1, attacker);
        vm.stopPrank();
        assertGt(attackerShares, 0, "attacker got shares");

        // 2) attacker donates a huge amount to try to spike share price.
        underlyingToken.mint(attacker, 1e30);
        vm.prank(attacker);
        underlyingToken.transfer(address(vault), 1e30);

        // 3) Even after a year (maxRate fully absorbing the donation), the victim still gets non-zero shares.
        skip(365 days);

        uint256 victimDeposit = 1e18;
        underlyingToken.mint(victim, victimDeposit);
        vm.startPrank(victim);
        underlyingToken.approve(address(vault), victimDeposit);
        uint256 victimShares = vault.deposit(victimDeposit, victim);
        vm.stopPrank();

        assertGt(victimShares, 0, "victim must receive non-zero shares");

        // Victim should be able to redeem something meaningful (not 0).
        // We don't claim "no loss" because some inflation is inherent — just that the attack isn't catastrophic.
        uint256 victimRedeemValue = vault.convertToAssets(victimShares);
        assertGt(victimRedeemValue, 0, "victim shares have value");
    }

    /// @notice With maxRate=0 (default), donations cannot register at all — the donation is dust to the vault.
    function testDonationInvisibleWhenMaxRateZero() public {
        // No setMaxRate call → maxRate = 0.
        underlyingToken.mint(attacker, 1e18);
        vm.startPrank(attacker);
        underlyingToken.approve(address(vault), 1);
        vault.deposit(1, attacker);
        underlyingToken.transfer(address(vault), 1e18 - 1);
        vm.stopPrank();

        skip(365 days);

        // Even after a year, the donation never gets absorbed into _totalAssets.
        assertEq(vault.totalAssets(), 1, "donation invisible without maxRate");
    }

    /* ── PENDING WITHDRAWAL PRICE LOCK ────────────────────────────────────────── */

    /// @notice A queued withdrawal request records assets at burn time. Subsequent price moves must
    /// not change what the queued user is owed.
    function testQueuedWithdrawalLockedAtRequestPrice() public {
        // Setup: victim deposits, allocator drains idle so the next withdrawal queues.
        uint256 deposit = 1_000e18;
        underlyingToken.mint(victim, deposit);
        vm.startPrank(victim);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, victim);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        // Victim requests withdraw of 400; it queues at the current share price.
        uint256 wantAssets = 400e18;
        vm.prank(victim);
        vault.withdraw(wantAssets, victim, victim);

        (uint128 lockedAssets,,) = vault.pendingWithdrawal(victim);
        assertEq(uint256(lockedAssets), wantAssets, "assets locked at request");

        // Massive interest accrues — share price doubles.
        vm.prank(governance);
        vault.setMaxRate(MAX_MAX_RATE);
        strategy.setInterest(deposit); // doubles strategy reported assets
        skip(365 days);
        vault.accrueInterest();

        // The queued request still owes exactly wantAssets — gains do NOT flow to pending requesters.
        (uint128 lockedAssetsAfter,,) = vault.pendingWithdrawal(victim);
        assertEq(uint256(lockedAssetsAfter), wantAssets, "still locked at original");

        // Bring liquidity back, operator fulfills, then claim — victim gets exactly the locked amount.
        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", wantAssets);
        address[] memory toFulfill = new address[](1);
        toFulfill[0] = victim;
        vm.prank(allocator);
        vault.fulfillWithdrawal(toFulfill);
        uint256 received = vault.claim(victim);
        assertEq(received, wantAssets, "received the locked amount");
    }

    /* ── PAUSE ASYMMETRY ─────────────────────────────────────────────────────── */

    /// @notice Sentinel can pause but cannot keep the vault paused forever — governance always unblocks.
    function testGovernanceAlwaysOverridesSentinelPause() public {
        vm.prank(sentinel);
        vault.pause();
        assertTrue(vault.paused());

        // Sentinel cannot unpause.
        vm.prank(sentinel);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vault.unpause();

        // Governance always can.
        vm.prank(governance);
        vault.unpause();
        assertFalse(vault.paused());
    }

    /// @notice Paused state blocks new inflows and allocations but withdraw/redeem/claim/forceDeallocate stay open.
    /// This is critical for user safety: a malicious sentinel cannot trap funds.
    function testPausedKeepsExitsOpen() public {
        // Setup: victim already in the vault.
        uint256 deposit = 1_000e18;
        underlyingToken.mint(victim, deposit);
        vm.startPrank(victim);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, victim);
        vm.stopPrank();

        // Sentinel pauses.
        vm.prank(sentinel);
        vault.pause();

        // Withdraw still works (immediate path because idle is full).
        vm.prank(victim);
        uint256 sharesBurned = vault.withdraw(500e18, victim, victim);
        assertGt(sharesBurned, 0, "withdraw open under pause");
        assertEq(underlyingToken.balanceOf(victim), 500e18, "exit succeeded");

        // But deposit is blocked.
        underlyingToken.mint(attacker, 100e18);
        vm.startPrank(attacker);
        underlyingToken.approve(address(vault), 100e18);
        vm.expectRevert(ErrorsLib.Paused.selector);
        vault.deposit(100e18, attacker);
        vm.stopPrank();

        // And allocation is blocked.
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.Paused.selector);
        vault.allocate(address(strategy), hex"", 100e18);
    }

    /* ── forceDeallocate CANNOT GRIEF WITHOUT APPROVAL ────────────────────────── */

    /// @notice Anyone CAN call `forceDeallocate(strategy, data, assets, onBehalf)` syntactically,
    /// but the internal `withdraw(penaltyAssets, vault, onBehalf)` path goes through the standard
    /// ERC20 allowance check: if `msg.sender != onBehalf` AND allowance is insufficient, the
    /// allowance subtraction underflows and the entire call reverts. So a 3rd party cannot grief
    /// `victim`'s shares unless `victim` explicitly approved them.
    function testForceDeallocateCannotGriefWithoutApproval() public {
        uint256 deposit = 1_000e18;
        underlyingToken.mint(victim, deposit);
        vm.startPrank(victim);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, victim);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        vm.prank(governance);
        strategyManager.setForceDeallocatePenalty(address(strategy), 0.01e18);

        // attacker has zero allowance from victim → withdraw's allowance subtraction underflows.
        vm.prank(attacker);
        vm.expectRevert(stdError.arithmeticError);
        vault.forceDeallocate(address(strategy), hex"", 100e18, victim);

        // victim's shares untouched.
        assertEq(vault.balanceOf(victim), deposit, "victim's shares safe");
    }

    /// @notice With explicit approval, a 3rd party CAN forceDeallocate on someone's behalf — useful
    /// for bot/relayer flows. Behaviour is identical to a regular `withdraw` going through allowance.
    function testForceDeallocateWorksWithApproval() public {
        uint256 deposit = 1_000e18;
        underlyingToken.mint(victim, deposit);
        vm.startPrank(victim);
        underlyingToken.approve(address(vault), deposit);
        uint256 victimShares = vault.deposit(deposit, victim);
        // Victim approves attacker for the share burn.
        vault.approve(attacker, type(uint256).max);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        vm.prank(governance);
        strategyManager.setForceDeallocatePenalty(address(strategy), 0.01e18);

        vm.prank(attacker);
        vault.forceDeallocate(address(strategy), hex"", 100e18, victim);

        // Victim paid the penalty (some shares burned).
        assertLt(vault.balanceOf(victim), victimShares, "penalty applied");
    }

    /* ── REENTRANCY / STATE-WRITE VIA GATE BLOCKED BY STATICCALL ──────────────── */

    /// @notice Gates are called via `IReceiveSharesGate(addr).canReceiveShares(...)` which, because
    /// the interface marks the function `view`, the compiler lowers to STATICCALL. A gate that tries
    /// to mutate state inside its hook therefore reverts at the EVM level — propagating up and
    /// blocking the deposit. This is the structural defence against gate-based reentrancy or
    /// state-mutation griefing.
    function testStateMutatingGateBlockedByStaticcall() public {
        RogueGate roguGate = new RogueGate();
        vm.prank(governance);
        vault.setReceiveSharesGate(address(roguGate));

        underlyingToken.mint(victim, 100e18);
        vm.startPrank(victim);
        underlyingToken.approve(address(vault), 100e18);
        // STATICCALL into the gate fails the moment the gate tries to write `counter += 1`.
        vm.expectRevert();
        vault.deposit(100e18, victim);
        vm.stopPrank();

        // Sanity: the gate's counter never moved (the staticcall reverted).
        assertEq(roguGate.counter(), 0, "gate state untouched");
    }

    /* ── ROLE-MANAGER WITHDRAW BY THIRD PARTY ─────────────────────────────────── */

    /// @notice Redeem can only burn shares with allowance — third party without approval cannot drain.
    function testCannotRedeemWithoutApproval() public {
        uint256 deposit = 1_000e18;
        underlyingToken.mint(victim, deposit);
        vm.startPrank(victim);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, victim);
        vm.stopPrank();

        // Attacker (no approval) cannot redeem on victim's behalf.
        vm.prank(attacker);
        vm.expectRevert(stdError.arithmeticError);
        vault.redeem(100e18, attacker, victim);
    }

    /* ── ALLOCATE BLOCKED WITHOUT STRATEGY REGISTRATION ─────────────────────────── */

    /// @notice Allocator cannot route assets to an arbitrary contract — the strategy must be registered.
    function testAllocateRejectsUnregisteredStrategy() public {
        StrategyMock rogue = new StrategyMock(address(vault), address(underlyingToken));
        underlyingToken.mint(address(vault), 100e18);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.NotStrategy.selector);
        vault.allocate(address(rogue), hex"", 100e18);
    }
}

/// @dev A gate that compiles fine (does NOT formally implement IReceiveSharesGate) but tries to
/// write state inside its hook. The vault casts to IReceiveSharesGate at call site, so the
/// compiler emits STATICCALL — and the EVM reverts the moment this contract attempts SSTORE.
contract RogueGate {
    uint256 public counter;

    function canReceiveShares(address) external returns (bool) {
        counter += 1; // STATICCALL ⇒ this revert propagates up
        return true;
    }
}
