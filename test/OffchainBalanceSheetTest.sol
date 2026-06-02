// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {OffchainNAVStrategy} from "../src/strategies/OffchainNAVStrategy.sol";

/// @notice Covers the BalanceSheet accounting (allocation / capital deployment / NAV reporting / staleness)
/// indirectly via a concrete OffchainNAVStrategy backed by the canonical Vault deployment from BaseTest.
contract OffchainBalanceSheetTest is BaseTest {
    bytes32 internal constant OFFCHAIN_REPORTER = keccak256("OFFCHAIN_REPORTER");
    bytes32 internal constant OFFCHAIN_MANAGER = keccak256("OFFCHAIN_MANAGER");

    address internal immutable reporter = makeAddr("reporter");
    address internal immutable manager = makeAddr("manager");
    address internal immutable custodian = makeAddr("custodian");

    OffchainNAVStrategy internal strategy;

    function setUp() public override {
        super.setUp();

        strategy = new OffchainNAVStrategy({
            _vault: address(vault),
            _asset: address(underlyingToken),
            _roleManager: address(roleManager),
            _custodian: custodian,
            _stalePeriod: 1 days,
            _minReportInterval: 0,
            _maxChangeBps: 0 // 0 disables max-change check; specific tests opt back in
        });

        // Per-strategy scoped roles live in the central RoleManager.
        bytes32 reporterRole = keccak256(abi.encode(address(strategy), OFFCHAIN_REPORTER));
        bytes32 managerRole = keccak256(abi.encode(address(strategy), OFFCHAIN_MANAGER));
        vm.startPrank(owner);
        roleManager.grantRole(reporterRole, reporter);
        roleManager.grantRole(managerRole, manager);
        vm.stopPrank();

        // Register the strategy with kind=2 (offchain NAV).
        vm.startPrank(governance);
        strategyManager.addStrategy(address(strategy), 2 /* OFFCHAIN_NAV */, 0, 0);
        strategyManager.increaseAbsoluteCap(abi.encode(address(strategy), address(underlyingToken)), type(uint128).max);
        strategyManager.increaseRelativeCap(abi.encode(address(strategy), address(underlyingToken)), WAD);
        vm.stopPrank();
    }

    function testInitialState() public view {
        assertEq(strategy.vault(), address(vault));
        assertEq(strategy.asset(), address(underlyingToken));
        assertEq(strategy.custodian(), custodian);
        assertEq(strategy.stalePeriod(), 1 days);
        assertEq(strategy.minReportInterval(), 0);
        assertEq(strategy.allocatedPrincipal(), 0);
        assertEq(strategy.deployedPrincipal(), 0);
        assertEq(strategy.reportedAssets(), 0);
        // No report yet — must be considered stale.
        assertTrue(strategy.isStale());
    }

    function testAllocateRecordsPrincipal(uint256 amount) public {
        amount = bound(amount, 1, type(uint96).max);
        underlyingToken.mint(address(vault), amount);

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", amount);

        assertEq(strategy.allocatedPrincipal(), amount);
        assertEq(underlyingToken.balanceOf(address(strategy)), amount);
    }

    function testDeployToCustodian(uint256 amount) public {
        amount = bound(amount, 1, type(uint96).max);
        underlyingToken.mint(address(vault), amount);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", amount);

        vm.expectEmit();
        emit EventsLib.CapitalDeployed(amount, custodian);
        vm.prank(manager);
        strategy.deployToCustodian(amount);

        assertEq(strategy.deployedPrincipal(), amount);
        assertEq(strategy.reportedAssets(), amount, "reportedAssets bumped at cost");
        assertEq(underlyingToken.balanceOf(custodian), amount);
        assertEq(underlyingToken.balanceOf(address(strategy)), 0);
    }

    function testDeployRequiresLiquidity() public {
        vm.prank(manager);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        strategy.deployToCustodian(1);
    }

    function testReportUpdatesNAVAndStaleness(uint256 navBefore, uint256 navAfter) public {
        navBefore = bound(navBefore, 0, type(uint96).max);
        navAfter = bound(navAfter, 0, type(uint96).max);

        bytes32 hash1 = keccak256("r1");
        vm.prank(reporter);
        strategy.report(navBefore, 0, hash1, "ipfs://1");

        assertFalse(strategy.isStale(), "fresh after report");
        assertEq(strategy.reportedAssets(), navBefore);
        assertEq(strategy.reportHash(), hash1);
        assertEq(strategy.lastReportTime(), block.timestamp);

        // After stalePeriod, becomes stale again.
        skip(1 days + 1);
        assertTrue(strategy.isStale(), "stale after stalePeriod");

        // A fresh report restores liveness.
        bytes32 hash2 = keccak256("r2");
        vm.prank(reporter);
        strategy.report(navAfter, 0, hash2, "ipfs://2");
        assertFalse(strategy.isStale());
        assertEq(strategy.reportedAssets(), navAfter);
    }

    function testReportRespectsMinInterval() public {
        // Tighten stalePeriod separately so it doesn't interact; set minInterval to 1h.
        vm.prank(governance);
        strategy.setMinReportInterval(1 hours);

        vm.prank(reporter);
        strategy.report(1e18, 0, keccak256("r0"), "");

        // Immediate second report must revert.
        vm.expectRevert(ErrorsLib.ReportTooSoon.selector);
        vm.prank(reporter);
        strategy.report(1e18, 0, keccak256("r1"), "");

        skip(1 hours);
        vm.prank(reporter);
        strategy.report(1e18, 0, keccak256("r2"), "");
    }

    function testReportRejectsLiquidityAboveAssets() public {
        vm.expectRevert(ErrorsLib.AvailableExceedsReportedAssets.selector);
        vm.prank(reporter);
        strategy.report(100, 101, keccak256("r"), "");
    }

    function testReportEnforcesMaxChangeBps() public {
        // Tighten maxChange to 1000 bps (10%).
        vm.prank(governance);
        strategy.setMaxChangeBps(1_000);

        vm.prank(reporter);
        strategy.report(1_000e18, 0, keccak256("r0"), "");

        // Trying to jump 50% must revert.
        vm.expectRevert(ErrorsLib.MaxChangeExceeded.selector);
        vm.prank(reporter);
        strategy.report(1_500e18, 0, keccak256("r1"), "");

        // Within bounds (5%) works.
        vm.prank(reporter);
        strategy.report(1_050e18, 0, keccak256("r2"), "");
    }

    function testRequestReturnAndRecord(uint256 amount) public {
        amount = bound(amount, 1, type(uint96).max);

        // Strict mode required for requestReturn/recordReturn.
        vm.prank(governance);
        strategy.setStrictMode(true);

        underlyingToken.mint(address(vault), amount);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", amount);
        vm.prank(manager);
        strategy.deployToCustodian(amount);

        // Reporter then reports current state with full liquidity available.
        vm.prank(reporter);
        strategy.report(amount, amount, keccak256("r0"), "");

        vm.expectEmit();
        emit EventsLib.ReturnRequested(amount);
        vm.prank(manager);
        strategy.requestReturn(amount);
        assertEq(strategy.pendingReceivable(), amount);
        assertEq(strategy.reportedAssets(), 0);
        assertEq(strategy.reportedAvailableLiquidity(), 0);

        // Custodian sends funds back, manager records them.
        vm.prank(custodian);
        underlyingToken.transfer(address(strategy), amount);

        vm.expectEmit();
        emit EventsLib.CapitalReturned(amount);
        vm.prank(manager);
        strategy.recordReturn(amount);
        assertEq(strategy.pendingReceivable(), 0);
        assertEq(strategy.deployedPrincipal(), 0);
    }

    /* ── Return-flow MODE (Simple vs Strict) ──────────────────────────────────── */

    /// @notice Default Simple mode disables requestReturn/recordReturn — they revert. The custodian
    /// send + REPORTER report is the entire reconciliation flow.
    function testSimpleModeDisablesRequestReturn() public {
        assertFalse(strategy.strictMode(), "default is Simple");

        vm.prank(manager);
        vm.expectRevert(OffchainNAVStrategy.StrictModeRequired.selector);
        strategy.requestReturn(100);

        vm.prank(manager);
        vm.expectRevert(OffchainNAVStrategy.StrictModeRequired.selector);
        strategy.recordReturn(100);
    }

    /// @notice GOV can toggle strict mode and Simple→Strict→Simple round-trip works when no in-transit
    /// balance is outstanding.
    function testSetStrictModeToggle() public {
        assertFalse(strategy.strictMode());

        vm.prank(governance);
        strategy.setStrictMode(true);
        assertTrue(strategy.strictMode());

        vm.prank(governance);
        strategy.setStrictMode(false);
        assertFalse(strategy.strictMode());
    }

    /// @notice Strict→Simple is rejected while a return is still in-transit (`pendingReceivable > 0`).
    /// Operator must complete `recordReturn` first to settle the in-transit balance.
    function testStrictToSimpleBlockedWhilePendingReceivable() public {
        uint256 amount = 100e18;

        vm.prank(governance);
        strategy.setStrictMode(true);

        underlyingToken.mint(address(vault), amount);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", amount);
        vm.prank(manager);
        strategy.deployToCustodian(amount);

        vm.prank(reporter);
        strategy.report(amount, amount, keccak256("r0"), "");

        // Create in-transit balance.
        vm.prank(manager);
        strategy.requestReturn(amount);
        assertEq(strategy.pendingReceivable(), amount);

        // Cannot switch back to Simple while in-transit balance is outstanding.
        vm.prank(governance);
        vm.expectRevert(OffchainNAVStrategy.PendingReceivableNonZero.selector);
        strategy.setStrictMode(false);

        // After recordReturn settles it, the switch goes through.
        vm.prank(custodian);
        underlyingToken.transfer(address(strategy), amount);
        vm.prank(manager);
        strategy.recordReturn(amount);
        assertEq(strategy.pendingReceivable(), 0);

        vm.prank(governance);
        strategy.setStrictMode(false);
        assertFalse(strategy.strictMode());
    }

    function testSetStrictModeOnlyGovernance(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        strategy.setStrictMode(true);
    }

    function testReporterRoleIsRequired(address rdm) public {
        vm.assume(rdm != reporter);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        strategy.report(0, 0, bytes32(0), "");
    }

    function testManagerRoleIsRequired(address rdm) public {
        vm.assume(rdm != manager);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        strategy.deployToCustodian(0);
    }

    function testStaleAssetsExcludeOffchain(uint256 amount, uint256 nav) public {
        amount = bound(amount, 1, type(uint96).max);
        nav = bound(nav, 1, type(uint96).max);

        underlyingToken.mint(address(strategy), amount);

        vm.prank(reporter);
        strategy.report(nav, 0, keccak256("r"), "");
        // Fresh: nav is included.
        assertEq(strategy.totalAssets(), amount + nav);

        skip(1 days + 1);
        // Stale: only onchain idle counts.
        assertEq(strategy.totalAssets(), amount);
    }

    /* ── skim (defensive token recovery) ──────────────────────────────────────── */

    function testSkimRecoversNonProtectedToken() public {
        address recipient = makeAddr("skimRecipient");
        ERC20Mock rewardToken = new ERC20Mock(18);
        rewardToken.mint(address(strategy), 500e18);

        vm.prank(governance);
        strategy.setSkimRecipient(recipient);

        vm.prank(recipient);
        strategy.skim(address(rewardToken));

        assertEq(rewardToken.balanceOf(recipient), 500e18);
        assertEq(rewardToken.balanceOf(address(strategy)), 0);
    }

    /// @notice The underlying asset is protected — skim cannot touch it (otherwise vault NAV idle would
    /// drain).
    function testSkimRevertsOnUnderlying() public {
        address recipient = makeAddr("skimRecipient");
        vm.prank(governance);
        strategy.setSkimRecipient(recipient);

        underlyingToken.mint(address(strategy), 100e18);

        vm.prank(recipient);
        vm.expectRevert(OffchainNAVStrategy.CannotSkimUnderlying.selector);
        strategy.skim(address(underlyingToken));
    }

    function testSkimOnlyRecipientCanCall(address rdm) public {
        address recipient = makeAddr("skimRecipient");
        vm.assume(rdm != recipient);
        vm.prank(governance);
        strategy.setSkimRecipient(recipient);

        ERC20Mock rewardToken = new ERC20Mock(18);
        rewardToken.mint(address(strategy), 100e18);

        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        strategy.skim(address(rewardToken));
    }

    function testSkimRevertsWhenRecipientUnset() public {
        ERC20Mock rewardToken = new ERC20Mock(18);
        rewardToken.mint(address(strategy), 100e18);

        // Default skimRecipient is address(0).
        vm.expectRevert(OffchainNAVStrategy.SkimRecipientUnset.selector);
        strategy.skim(address(rewardToken));
    }

    function testSetSkimRecipientOnlyGovernance(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));
        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        strategy.setSkimRecipient(makeAddr("anyone"));
    }
}
