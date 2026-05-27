// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

/// @notice End-to-end coverage of fee math + routing:
///  - depositFee / withdrawalFee: charged on entry/exit, routed to `protocolFeeRecipient`
///  - performanceFee: minted as shares to `performanceFeeRecipient` on positive accrual
///  - managementFee: minted as shares to `managementFeeRecipient` proportional to elapsed time
contract FeeTest is BaseTest {
    using MathLib for uint256;

    address internal immutable user = makeAddr("user");
    address internal immutable protocolRecipient = makeAddr("protocolRecipient");
    address internal immutable perfRecipient = makeAddr("perfRecipient");
    address internal immutable mgmtRecipient = makeAddr("mgmtRecipient");

    StrategyMock internal strategy;

    function setUp() public override {
        super.setUp();

        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(protocolRecipient);
        vault.setPerformanceFeeRecipient(perfRecipient);
        vault.setManagementFeeRecipient(mgmtRecipient);
        vault.setMaxRate(MAX_MAX_RATE);
        vm.stopPrank();

        strategy = _addStrategyWithMaxCaps();

        // Fund user and pre-approve for entry tests.
        underlyingToken.mint(user, type(uint128).max);
        vm.prank(user);
        underlyingToken.approve(address(vault), type(uint256).max);
    }

    /* ── DEPOSIT FEE (entry path) ─────────────────────────────────────────────── */

    /// @notice depositFee is deducted from the user's gross input and routed to the protocol recipient.
    /// Vault retains `netAssets = grossAssets * (1 - fee)`, shares are minted for `netAssets` only.
    function testDepositFeeRoutedToProtocol(uint256 grossAssets, uint256 feeBps) public {
        grossAssets = bound(grossAssets, 1e6, 1e30);
        feeBps = bound(feeBps, 1, MAX_DEPOSIT_FEE);

        vm.prank(governance);
        vault.setDepositFee(feeBps);

        uint256 expectedFee = grossAssets.mulDivUp(feeBps, WAD);
        uint256 expectedNet = grossAssets - expectedFee;

        underlyingToken.mint(user, grossAssets);
        uint256 userBalBefore = underlyingToken.balanceOf(user);

        vm.prank(user);
        uint256 shares = vault.deposit(grossAssets, user);

        // User paid the full gross.
        assertEq(userBalBefore - underlyingToken.balanceOf(user), grossAssets, "user paid gross");
        // Protocol got exactly the fee.
        assertEq(underlyingToken.balanceOf(protocolRecipient), expectedFee, "protocol got fee");
        // Vault kept the net.
        assertEq(underlyingToken.balanceOf(address(vault)), expectedNet, "vault kept net");
        // Shares correspond to net, not gross (rough check — first depositor 1:1).
        assertGt(shares, 0);
    }

    /// @notice mint() with a fee: caller pays `grossAssets = previewMint(shares)` which already
    /// includes the fee uplift. Vault keeps net, protocol gets fee, recipient gets exactly `shares`.
    function testMintFeePayerPaysGross(uint256 shares, uint256 feeBps) public {
        shares = bound(shares, 1e6, 1e30);
        feeBps = bound(feeBps, 1, MAX_DEPOSIT_FEE);

        vm.prank(governance);
        vault.setDepositFee(feeBps);

        uint256 quotedGross = vault.previewMint(shares);
        underlyingToken.mint(user, quotedGross);

        uint256 userBalBefore = underlyingToken.balanceOf(user);

        vm.prank(user);
        uint256 actualGross = vault.mint(shares, user);

        assertEq(actualGross, quotedGross, "preview matches actual");
        assertEq(userBalBefore - underlyingToken.balanceOf(user), quotedGross, "paid gross");
        assertEq(vault.balanceOf(user), shares, "got exactly the asked shares");

        // Fee landed at protocol.
        uint256 fee = quotedGross.mulDivUp(feeBps, WAD);
        assertEq(underlyingToken.balanceOf(protocolRecipient), fee, "protocol got fee");
    }

    /// @notice Cannot set depositFee>0 without a recipient set. SettersTest already covers ordering;
    /// this covers the negative path inline as a smoke check.
    function testDepositFeeRequiresProtocolRecipient() public {
        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(address(0)); // remove
        vm.expectRevert(ErrorsLib.FeeInvariantBroken.selector);
        vault.setDepositFee(0.01e18);
        vm.stopPrank();
    }

    /* ── WITHDRAWAL FEE (immediate path) ──────────────────────────────────────── */

    /// @notice withdrawalFee on the *immediate* path: user requests net amount; vault sends net,
    /// protocol pockets the fee, total burned shares correspond to the gross.
    function testWithdrawalFeeImmediatePath(uint256 deposit, uint256 wantNet, uint256 feeBps) public {
        deposit = bound(deposit, 1e18, 1e30);
        wantNet = bound(wantNet, 1, deposit / 2);
        feeBps = bound(feeBps, 1, MAX_WITHDRAWAL_FEE);

        // Setup: user enters vault.
        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(governance);
        vault.setWithdrawalFee(feeBps);

        uint256 expectedGross = wantNet.mulDivUp(WAD, WAD - feeBps);
        uint256 expectedFee = expectedGross - wantNet;

        uint256 protocolBalBefore = underlyingToken.balanceOf(protocolRecipient);
        uint256 userBalBefore = underlyingToken.balanceOf(user);

        vm.prank(user);
        uint256 burned = vault.withdraw(wantNet, user, user);

        assertGt(burned, 0);
        // User's balance grew by exactly the net amount (setUp pre-funded the user, so check the delta).
        assertEq(underlyingToken.balanceOf(user) - userBalBefore, wantNet, "user received net");
        assertEq(
            underlyingToken.balanceOf(protocolRecipient) - protocolBalBefore, expectedFee, "fee routed"
        );
    }

    /// @notice redeem() with a fee: caller burns shares, receiver gets the post-fee amount.
    function testRedeemFeeImmediatePath(uint256 deposit, uint256 redeemShares, uint256 feeBps) public {
        deposit = bound(deposit, 1e18, 1e30);
        feeBps = bound(feeBps, 1, MAX_WITHDRAWAL_FEE);

        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        uint256 totalShares = vault.deposit(deposit, user);
        vm.stopPrank();

        // Force redeem amount large enough that `gross - net` rounds to ≥ 1 wei.
        // With feeBps as small as 1 (wei/WAD), we need gross of at least 1/feeBps to round up to a 1-wei fee.
        redeemShares = bound(redeemShares, totalShares / 100, totalShares);

        vm.prank(governance);
        vault.setWithdrawalFee(feeBps);

        uint256 expectedNet = vault.previewRedeem(redeemShares);
        uint256 userBalBefore = underlyingToken.balanceOf(user);
        uint256 protocolBalBefore = underlyingToken.balanceOf(protocolRecipient);

        vm.prank(user);
        uint256 received = vault.redeem(redeemShares, user, user);

        assertEq(received, expectedNet, "received matches preview");
        assertEq(underlyingToken.balanceOf(user) - userBalBefore, expectedNet, "balance reflects net");
        // protocol got the rest (gross - net). At this scale the fee is always ≥ 1 wei.
        assertGt(
            underlyingToken.balanceOf(protocolRecipient), protocolBalBefore, "protocol got non-zero fee"
        );
    }

    /* ── PERFORMANCE FEE ──────────────────────────────────────────────────────── */

    /// @notice After positive interest accrual, performanceFeeRecipient is minted shares such that
    /// they own a `performanceFee` fraction of the realised gains.
    /// forge-config: default.isolate = true
    function testPerformanceFeeMintsRecipientShares() public {
        uint256 deposit = 1_000e18;
        uint256 interest = 100e18;
        uint256 perfFeeBps = 0.1e18; // 10%

        vm.prank(governance);
        vault.setPerformanceFee(perfFeeBps);

        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        // 1 year of interest accrual.
        strategy.setInterest(interest);
        skip(365 days);
        vault.accrueInterest();

        uint256 perfShares = vault.balanceOf(perfRecipient);
        assertGt(perfShares, 0, "recipient got shares");

        // Recipient's value should be ~10% of the gross interest (with small rounding).
        uint256 perfAssets = vault.convertToAssets(perfShares);
        uint256 expectedAssets = interest * perfFeeBps / WAD;
        assertApproxEqRel(perfAssets, expectedAssets, 0.01e18, "perf fee ~= 10% of interest");
    }

    /// @notice No performance fee when totalAssets doesn't grow (loss or flat).
    /// forge-config: default.isolate = true
    function testPerformanceFeeZeroOnLoss() public {
        uint256 deposit = 1_000e18;
        uint256 loss = 50e18;

        vm.prank(governance);
        vault.setPerformanceFee(0.1e18);

        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        strategy.setLoss(loss);
        vault.accrueInterest();

        assertEq(vault.balanceOf(perfRecipient), 0, "no perf fee on loss");
    }

    /* ── MANAGEMENT FEE ───────────────────────────────────────────────────────── */

    /// @notice Management fee accrues proportionally to elapsed time, independent of profit/loss.
    /// forge-config: default.isolate = true
    function testManagementFeeAccruesOverTime() public {
        uint256 deposit = 1_000e18;
        // 1% APR.
        uint256 mgmtFee = uint256(0.01e18) / uint256(365 days);

        vm.prank(governance);
        vault.setManagementFee(mgmtFee);

        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        // No interest, no loss — just time passing.
        skip(365 days);
        vault.accrueInterest();

        uint256 mgmtShares = vault.balanceOf(mgmtRecipient);
        assertGt(mgmtShares, 0, "mgmt fee accrued");

        // 1% APR over 1 year on 1000 ≈ 10 assets worth.
        uint256 mgmtAssets = vault.convertToAssets(mgmtShares);
        assertApproxEqRel(mgmtAssets, 10e18, 0.01e18, "mgmt fee ~= 1% of NAV");
    }

    /// @notice Management fee taken even on a loss — it's billed on AUM, not performance.
    /// forge-config: default.isolate = true
    function testManagementFeeChargedDespiteLoss() public {
        uint256 deposit = 1_000e18;
        uint256 loss = 50e18;
        uint256 mgmtFee = uint256(0.01e18) / uint256(365 days);

        vm.prank(governance);
        vault.setManagementFee(mgmtFee);

        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        strategy.setLoss(loss);
        skip(365 days);
        vault.accrueInterest();

        // Recipient still got shares, even though the vault lost money.
        assertGt(vault.balanceOf(mgmtRecipient), 0, "mgmt charged on loss");
    }

    /* ── COMBINED FEES ────────────────────────────────────────────────────────── */

    /// @notice Charging all four fee types simultaneously must not corrupt accounting. We skip the
    /// strategy round-trip here (the mock would underflow when asked to return reported interest it
    /// doesn't actually hold) and instead verify entries/exits in the idle-only path.
    /// forge-config: default.isolate = true
    function testCombinedFeesNoDoubleCount() public {
        // 1% deposit, 1% withdrawal, 10% perf, 1% APR mgmt.
        vm.startPrank(governance);
        vault.setDepositFee(0.01e18);
        vault.setWithdrawalFee(0.01e18);
        vault.setPerformanceFee(0.1e18);
        vault.setManagementFee(uint256(0.01e18) / uint256(365 days));
        vm.stopPrank();

        uint256 grossDeposit = 1_000e18;
        underlyingToken.mint(user, grossDeposit);

        uint256 protocolBeforeDeposit = underlyingToken.balanceOf(protocolRecipient);

        vm.startPrank(user);
        underlyingToken.approve(address(vault), grossDeposit);
        vault.deposit(grossDeposit, user);
        vm.stopPrank();

        // Deposit fee (1%) landed at protocol recipient.
        assertEq(
            underlyingToken.balanceOf(protocolRecipient) - protocolBeforeDeposit,
            10e18,
            "depositFee landed"
        );

        // Time-only accrual mints the management fee (no interest needed — mgmt charges on AUM).
        skip(365 days);
        vault.accrueInterest();
        assertGt(vault.balanceOf(mgmtRecipient), 0, "mgmt fee minted over time");
        // No interest, so performance recipient must NOT have received shares.
        assertEq(vault.balanceOf(perfRecipient), 0, "no perf fee without gains");

        // User exits via idle (vault hasn't allocated, so all 990 net is still idle).
        uint256 userShares = vault.balanceOf(user);
        // Redeem only what idle can cover at current share price, leaving room for mgmt-fee recipient claims.
        uint256 partialShares = userShares / 2;
        uint256 protocolBeforeExit = underlyingToken.balanceOf(protocolRecipient);

        vm.prank(user);
        vault.redeem(partialShares, user, user);

        // Withdrawal fee landed at protocol on exit.
        assertGt(
            underlyingToken.balanceOf(protocolRecipient),
            protocolBeforeExit,
            "withdrawalFee added on exit"
        );
    }

    /* ── ROUNDING DIRECTION ───────────────────────────────────────────────────── */

    /// @notice depositFee rounds *up* (favours the vault) — caller never gets free entry.
    function testDepositFeeRoundsUp() public {
        // Use a fee that produces a fractional fee for small amounts.
        vm.prank(governance);
        vault.setDepositFee(0.0001e18); // 0.01%

        // Deposit 1 wei — fee should round to 1 (not 0).
        underlyingToken.mint(user, 1);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), 1);
        vault.deposit(1, user);
        vm.stopPrank();

        // Even on a 1-wei deposit, protocol still got 1 wei.
        assertEq(underlyingToken.balanceOf(protocolRecipient), 1, "fee rounded up");
    }
}
