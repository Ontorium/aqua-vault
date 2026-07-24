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
        strategyManager.addStrategy(address(strategy), 2 /* OFFCHAIN_NAV */, 0);
        strategyManager.increaseAbsoluteCap(abi.encode(address(strategy), address(underlyingToken)), type(uint128).max);
        strategyManager.increaseRelativeCap(abi.encode(address(strategy), address(underlyingToken)), WAD);
        vm.stopPrank();
    }

    function testInitialState() public view {
        assertEq(strategy.vault(), address(vault));
        assertEq(strategy.asset(), address(underlyingToken));
        assertEq(strategy.custodian(), custodian);
        assertEq(strategy.stalePeriod(), 1 days);
        assertEq(strategy.allocatedPrincipal(), 0);
        assertEq(strategy.deployedPrincipal(), 0);
        assertEq(strategy.reportedAssets(), 0);
        // No report yet — must be considered stale.
        assertTrue(strategy.isStale());
        assertFalse(
            strategyManager.hasBlockingStaleOffchainExposure(),
            "stale strategy without offchain exposure does not block"
        );
    }

    function testAllocateRecordsPrincipal(uint256 amount) public {
        amount = bound(amount, 1, type(uint96).max);
        underlyingToken.mint(address(vault), amount);

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", amount);

        assertEq(strategy.allocatedPrincipal(), amount);
        assertEq(underlyingToken.balanceOf(address(strategy)), amount);
    }

    function testForceDeallocateUnsupportedForOffchainStrategy() public {
        uint256 amount = 100e18;
        underlyingToken.mint(address(vault), amount);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", amount);

        vm.expectRevert(ErrorsLib.ForceDeallocateUnsupported.selector);
        vault.forceDeallocate(address(strategy), hex"", amount, address(this));

        assertEq(strategy.allocatedPrincipal(), amount, "allocation unchanged");
        assertEq(underlyingToken.balanceOf(address(strategy)), amount, "strategy funds untouched");
        assertEq(underlyingToken.balanceOf(address(vault)), 0, "nothing force-returned");
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

    /// @notice End-to-end: a trusted offchain NAV gain bypasses maxRate and raises the share price immediately.
    /// Capital is allocated, deployed to the custodian and confirmed at cost; a later report of a higher NAV
    /// flows reportedAssets → strategy totalAssets → vault totalAssets in the same transaction.
    /// forge-config: default.isolate = true
    function testOffchainNAVGainRaisesSharePrice() public {
        uint256 deposit = 1_000e18;
        address user = makeAddr("user");
        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        uint256 shares = vault.deposit(deposit, user);
        vm.stopPrank();

        // Allocate to the offchain strategy, deploy to the custodian, and confirm NAV at cost.
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);
        vm.prank(manager);
        strategy.deployToCustodian(deposit);
        vm.prank(reporter);
        strategy.report(deposit, 0, keccak256("confirm"), "ipfs://confirm");

        // Baseline: one share ~ 1 underlying.
        uint256 assetsPerShareBefore = vault.convertToAssets(shares);
        assertApproxEqAbs(assetsPerShareBefore, deposit, 1, "baseline ~1:1");

        // A year later the custodian reports a 10% NAV gain.
        skip(365 days);
        vm.roll(block.number + 1);
        vm.prank(reporter);
        strategy.report(deposit + 100e18, 0, keccak256("gain"), "ipfs://gain");

        // maxRate remains zero, but the authenticated offchain report is reflected immediately.
        assertEq(vault.maxRate(), 0);
        uint256 assetsPerShareAfter = vault.convertToAssets(shares);
        assertGt(assetsPerShareAfter, assetsPerShareBefore, "share price increased");
        assertApproxEqAbs(assetsPerShareAfter, deposit + 100e18, 2, "NAV gain reflected in share value");
        assertApproxEqAbs(vault.totalAssets(), deposit + 100e18, 1, "vault totalAssets grew by NAV gain");
    }

    /// @notice A depositor entering after a lumpy gain pays the post-report price and cannot capture it.
    function testOffchainNAVGainIsNotDilutedByLaterDeposit() public {
        uint256 initialDeposit = 1_000e18;
        address existingHolder = makeAddr("existingHolder");
        underlyingToken.mint(existingHolder, initialDeposit);
        vm.startPrank(existingHolder);
        underlyingToken.approve(address(vault), initialDeposit);
        uint256 existingShares = vault.deposit(initialDeposit, existingHolder);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", initialDeposit);
        vm.prank(manager);
        strategy.deployToCustodian(initialDeposit);
        vm.prank(reporter);
        strategy.report(initialDeposit, 0, keccak256("cost"), "ipfs://cost");

        vm.roll(block.number + 1);
        vm.prank(reporter);
        strategy.report(1_200e18, 0, keccak256("gain"), "ipfs://gain");
        assertApproxEqAbs(vault.convertToAssets(existingShares), 1_200e18, 2, "gain belongs to existing holder");

        address laterDepositor = makeAddr("laterDepositor");
        underlyingToken.mint(laterDepositor, initialDeposit);
        vm.startPrank(laterDepositor);
        underlyingToken.approve(address(vault), initialDeposit);
        uint256 laterShares = vault.deposit(initialDeposit, laterDepositor);
        vm.stopPrank();

        assertLt(laterShares, initialDeposit, "later depositor enters at post-report price");
        assertApproxEqAbs(laterShares, 833_333333333333333333, 2, "shares priced at 1.2 assets");
        assertApproxEqAbs(
            vault.convertToAssets(existingShares), 1_200e18, 3, "later deposit does not dilute prior gain"
        );
    }

    /// @notice Only the report delta bypasses maxRate; an unrelated direct donation remains smoothed.
    function testOffchainReportDoesNotBypassMaxRateForDonation() public {
        uint256 deposit = 1_000e18;
        address user = makeAddr("user");
        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);
        vm.prank(manager);
        strategy.deployToCustodian(deposit);
        vm.prank(reporter);
        strategy.report(deposit, 0, keccak256("cost"), "ipfs://cost");

        underlyingToken.mint(address(vault), 500e18);
        vm.roll(block.number + 1);
        vm.prank(reporter);
        strategy.report(1_100e18, 0, keccak256("gain"), "ipfs://gain");

        assertEq(vault.maxRate(), 0);
        assertEq(vault.totalAssets(), 1_100e18, "only trusted report gain bypasses maxRate");
    }

    function testOffchainNAVLossIsReflectedImmediately() public {
        uint256 deposit = 1_000e18;
        address user = makeAddr("user");
        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);
        vm.prank(manager);
        strategy.deployToCustodian(deposit);
        vm.prank(reporter);
        strategy.report(deposit, 0, keccak256("cost"), "ipfs://cost");

        vm.roll(block.number + 1);
        vm.prank(reporter);
        strategy.report(700e18, 0, keccak256("loss"), "ipfs://loss");

        assertEq(vault.totalAssets(), 700e18);
    }

    function testSyncOffchainNAVRejectsNonStrategyCaller() public {
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vault.syncOffchainNAV(0);
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
        vm.roll(block.number + 1);
        vm.prank(reporter);
        strategy.report(navAfter, 0, hash2, "ipfs://2");
        assertFalse(strategy.isStale());
        assertEq(strategy.reportedAssets(), navAfter);
    }

    function testReportRejectsSecondSubmissionInSameBlock() public {
        vm.prank(reporter);
        strategy.report(1e18, 0, keccak256("r0"), "");

        vm.expectRevert(ErrorsLib.ReportAlreadySubmittedThisBlock.selector);
        vm.prank(reporter);
        strategy.report(1e18, 0, keccak256("r1"), "");

        assertEq(strategy.reportHash(), keccak256("r0"), "first report remains active");

        vm.roll(block.number + 1);
        vm.prank(reporter);
        strategy.report(1e18, 0, keccak256("r1"), "");
        assertEq(strategy.reportHash(), keccak256("r1"), "next-block report accepted");
    }

    function testReportRejectsLiquidityAboveAssets() public {
        vm.expectRevert(ErrorsLib.AvailableExceedsReportedAssets.selector);
        vm.prank(reporter);
        strategy.report(100, 101, keccak256("r"), "");
    }

    function testReportEnforcesMaxChangeBpsOnGain() public {
        // Tighten maxChange to 1000 bps (10%).
        vm.prank(governance);
        strategy.setMaxChangeBps(1_000);

        vm.prank(reporter);
        strategy.report(1_000e18, 0, keccak256("r0"), "");

        // Trying to jump 50% must revert.
        vm.roll(block.number + 1);
        vm.expectRevert(ErrorsLib.MaxChangeExceeded.selector);
        vm.prank(reporter);
        strategy.report(1_500e18, 0, keccak256("r1"), "");

        // Within bounds (5%) works.
        vm.prank(reporter);
        strategy.report(1_050e18, 0, keccak256("r2"), "");
    }

    function testReportAllowsLossBeyondMaxChangeBps() public {
        vm.prank(governance);
        strategy.setMaxChangeBps(1_000); // 10% gain cap.

        vm.prank(reporter);
        strategy.report(1_000e18, 0, keccak256("r0"), "");

        // A 50% loss exceeds the configured bps but must still be reported and reflected immediately.
        vm.roll(block.number + 1);
        vm.prank(reporter);
        strategy.report(500e18, 0, keccak256("loss"), "");

        assertEq(strategy.reportedAssets(), 500e18);
        assertEq(vault.totalAssets(), 500e18);
    }

    function testReturnCapitalAtomicallyReconciles(uint256 amount) public {
        amount = bound(amount, 1, type(uint96).max);

        underlyingToken.mint(address(vault), amount);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", amount);
        vm.prank(manager);
        strategy.deployToCustodian(amount);

        // Reporter then reports current state with full liquidity available.
        vm.prank(reporter);
        strategy.report(amount, amount, keccak256("r0"), "");

        uint256 totalBefore = strategy.totalAssets();
        vm.prank(custodian);
        underlyingToken.approve(address(strategy), amount);

        vm.expectEmit();
        emit EventsLib.CapitalReturned(amount);
        vm.prank(custodian);
        strategy.returnCapital(amount);

        assertEq(strategy.totalAssets(), totalBefore, "atomic return preserves NAV");
        assertEq(underlyingToken.balanceOf(address(strategy)), amount, "underlying arrived onchain");
        assertEq(strategy.reportedAssets(), 0, "returned value removed from offchain NAV");
        assertEq(strategy.reportedAvailableLiquidity(), 0, "returned liquidity removed from offchain book");
        assertEq(strategy.deployedPrincipal(), 0);
    }

    /// @notice Realized offchain profit can be atomically returned and fully deallocated.
    /// Principal accounting floors at zero instead of trapping the excess profit.
    function testReturnedProfitCanBeFullyDeallocated() public {
        uint256 principal = 1_000e18;
        uint256 profit = 100e18;
        uint256 returnedAssets = principal + profit;

        underlyingToken.mint(address(vault), principal);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", principal);
        vm.prank(manager);
        strategy.deployToCustodian(principal);

        // The reporter marks the profitable position and confirms that all of it can be returned.
        vm.prank(reporter);
        strategy.report(returnedAssets, returnedAssets, keccak256("profitable-nav"), "");

        underlyingToken.mint(custodian, profit);
        vm.startPrank(custodian);
        underlyingToken.approve(address(strategy), returnedAssets);
        strategy.returnCapital(returnedAssets);
        vm.stopPrank();

        assertEq(strategy.reportedAssets(), 0, "offchain NAV cleared atomically");
        assertEq(strategy.reportedAvailableLiquidity(), 0, "offchain liquidity cleared atomically");
        assertEq(strategy.deployedPrincipal(), 0, "deployed principal cleared");
        assertEq(strategy.totalAssets(), returnedAssets, "onchain idle includes principal and profit once");

        vm.prank(allocator);
        vault.deallocate(address(strategy), hex"", returnedAssets);

        assertEq(strategy.allocatedPrincipal(), 0, "principal accounting floors at zero");
        assertEq(strategy.totalAssets(), 0, "strategy fully emptied");
        assertEq(underlyingToken.balanceOf(address(vault)), returnedAssets, "vault receives principal and profit");
        assertEq(strategyManager.allocation(strategy.strategyId()), 0, "cap accounting floors at zero");

        vm.prank(governance);
        strategyManager.removeStrategy(address(strategy));
        assertFalse(strategyManager.isStrategy(address(strategy)), "empty strategy is removable");
    }

    function testReturnCapitalOnlyCustodian() public {
        uint256 amount = 100e18;

        underlyingToken.mint(address(vault), amount);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", amount);
        vm.prank(manager);
        strategy.deployToCustodian(amount);

        vm.prank(reporter);
        strategy.report(amount, amount, keccak256("r0"), "");

        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(manager);
        strategy.returnCapital(amount);
    }

    function testReturnCapitalRejectsMoreThanReportedLiquidity() public {
        uint256 amount = 100e18;

        underlyingToken.mint(address(vault), amount);
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", amount);
        vm.prank(manager);
        strategy.deployToCustodian(amount);
        vm.prank(reporter);
        strategy.report(amount, 40e18, keccak256("partially-liquid"), "");

        vm.prank(custodian);
        underlyingToken.approve(address(strategy), amount);

        vm.expectRevert(ErrorsLib.RequestExceedsAvailableLiquidity.selector);
        vm.prank(custodian);
        strategy.returnCapital(50e18);

        assertEq(underlyingToken.balanceOf(custodian), amount, "failed return moves no tokens");
        assertEq(underlyingToken.balanceOf(address(strategy)), 0, "strategy receives nothing on revert");
        assertEq(strategy.reportedAssets(), amount, "reported NAV unchanged on revert");
    }

    function testReturnCapitalRejectsZero() public {
        vm.expectRevert(ErrorsLib.InvalidRequest.selector);
        vm.prank(custodian);
        strategy.returnCapital(0);
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

    function testStaleAssetsRetainLastReportedNAV(uint256 amount, uint256 nav, uint256 liquidity) public {
        amount = bound(amount, 1, type(uint96).max);
        nav = bound(nav, 1, type(uint96).max);
        liquidity = bound(liquidity, 0, nav);

        underlyingToken.mint(address(strategy), amount);

        vm.prank(reporter);
        strategy.report(nav, liquidity, keccak256("r"), "");
        assertEq(strategy.totalAssets(), amount + nav);
        assertEq(strategy.availableLiquidity(), amount + liquidity);

        skip(1 days + 1);
        assertEq(strategy.totalAssets(), amount + nav, "stale keeps last reported NAV");
        assertEq(strategy.availableLiquidity(), amount, "stale liquidity falls back to idle");
    }

    /// @notice Stale offchain marks no longer crash totalAssets, but new entry is blocked until a fresh
    /// report arrives.
    /// forge-config: default.isolate = true
    function testStaleOffchainExposureBlocksDepositAndMint() public {
        vm.prank(governance);
        vault.setMaxRate(MAX_MAX_RATE);

        uint256 deposit = 1_000e18;
        address user = makeAddr("user");
        address attacker = makeAddr("attacker");

        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);
        vm.prank(manager);
        strategy.deployToCustodian(deposit);
        vm.prank(reporter);
        strategy.report(deposit, deposit, keccak256("confirm"), "ipfs://confirm");

        skip(1 days + 1);
        assertTrue(strategy.isStale(), "strategy stale");
        assertEq(strategy.totalAssets(), deposit, "last reported NAV retained");
        assertEq(vault.totalAssets(), deposit, "vault NAV does not crash");

        underlyingToken.mint(attacker, deposit);
        vm.startPrank(attacker);
        underlyingToken.approve(address(vault), deposit);
        vm.expectRevert(ErrorsLib.StaleOffchainStrategy.selector);
        vault.deposit(deposit, attacker);

        vm.expectRevert(ErrorsLib.StaleOffchainStrategy.selector);
        vault.mint(100e18, attacker);
        vm.stopPrank();
    }

    /// @notice A stale offchain mark routes an otherwise liquid exit into the queue. A fresh report is
    /// required before the allocator can price and fulfill the escrowed shares.
    /// forge-config: default.isolate = true
    function testStaleOffchainExposureQueuesLiquidWithdrawalUntilFreshReport() public {
        uint256 deposit = 1_000e18;
        uint256 deployed = 100e18;
        uint256 requested = 200e18;
        address user = makeAddr("staleExitUser");

        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        uint256 userShares = vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deployed);
        vm.prank(manager);
        strategy.deployToCustodian(deployed);
        vm.prank(reporter);
        strategy.report(deployed, 0, keccak256("initial"), "ipfs://initial");
        assertFalse(strategyManager.hasBlockingStaleOffchainExposure(), "fresh exposure does not block");

        skip(1 days + 1);
        assertTrue(strategy.isStale(), "offchain NAV is stale");
        assertTrue(strategyManager.hasBlockingStaleOffchainExposure(), "stale exposure blocks pricing");
        assertEq(underlyingToken.balanceOf(address(vault)), deposit - deployed, "idle covers request");

        uint256 expectedShares = vault.previewWithdraw(requested);
        vm.prank(user);
        uint256 queuedShares = vault.withdraw(requested, user, user);

        assertEq(queuedShares, expectedShares, "request uses estimated shares");
        assertEq(underlyingToken.balanceOf(user), 0, "stale exit is not paid immediately");
        assertEq(vault.balanceOf(user), userShares - queuedShares, "shares removed from user custody");
        assertEq(vault.balanceOf(address(vault)), queuedShares, "shares escrowed in vault");
        (uint128 pendingAssets, uint128 pendingShares,) = vault.pendingWithdrawal(user);
        assertEq(uint256(pendingAssets), requested, "request-time asset estimate stored");
        assertEq(uint256(pendingShares), queuedShares, "pending shares stored");

        address[] memory receivers = new address[](1);
        receivers[0] = user;
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.StaleOffchainStrategy.selector);
        vault.fulfillWithdrawal(receivers);

        uint256[] memory partialShares = new uint256[](1);
        partialShares[0] = queuedShares / 2;
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.StaleOffchainStrategy.selector);
        vault.fulfillWithdrawalPartial(receivers, partialShares);

        vm.roll(block.number + 1);
        vm.prank(reporter);
        strategy.report(deployed, 0, keccak256("fresh"), "ipfs://fresh");
        assertFalse(strategyManager.hasBlockingStaleOffchainExposure(), "fresh report clears block");
        vm.prank(allocator);
        vault.fulfillWithdrawal(receivers);

        assertEq(vault.claim(user), requested, "fresh NAV settlement is claimable");
        assertEq(underlyingToken.balanceOf(user), requested, "user receives fixed claim amount");
    }

    /// @notice Fresh offchain exposure does not disable the normal immediate path when idle is sufficient.
    function testFreshOffchainExposureAllowsLiquidImmediateWithdrawal() public {
        uint256 deposit = 1_000e18;
        uint256 deployed = 100e18;
        uint256 requested = 200e18;
        address user = makeAddr("freshExitUser");

        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deployed);
        vm.prank(manager);
        strategy.deployToCustodian(deployed);
        vm.prank(reporter);
        strategy.report(deployed, 0, keccak256("fresh-immediate"), "ipfs://fresh-immediate");

        vm.prank(user);
        vault.withdraw(requested, user, user);

        assertEq(underlyingToken.balanceOf(user), requested, "fresh liquid exit pays immediately");
        (, uint128 pendingShares,) = vault.pendingWithdrawal(user);
        assertEq(uint256(pendingShares), 0, "no queue entry created");
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
