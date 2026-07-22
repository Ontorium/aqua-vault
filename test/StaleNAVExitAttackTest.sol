// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {OffchainNAVStrategy} from "../src/strategies/OffchainNAVStrategy.sol";

/// @notice Verifies that a stale offchain NAV cannot be locked in by an early redemption request.
/// Shares are escrowed at request time and priced only after a fresh report at fulfillment.
contract StaleNAVExitAttackTest is BaseTest {
    bytes32 internal constant OFFCHAIN_REPORTER = keccak256("OFFCHAIN_REPORTER");
    bytes32 internal constant OFFCHAIN_MANAGER = keccak256("OFFCHAIN_MANAGER");

    address internal immutable reporter = makeAddr("reporter");
    address internal immutable manager = makeAddr("manager");
    address internal immutable custodian = makeAddr("custodian");
    address internal immutable blackhole = makeAddr("blackhole"); // absorbs the simulated offchain loss

    address internal immutable attacker = makeAddr("attacker"); // informed holder who exits early
    address internal immutable victim = makeAddr("victim"); // LP who stays and eats the loss

    OffchainNAVStrategy internal strategy;

    function setUp() public override {
        super.setUp();

        strategy = new OffchainNAVStrategy({
            _vault: address(vault),
            _asset: address(underlyingToken),
            _roleManager: address(roleManager),
            _custodian: custodian,
            _stalePeriod: 1 days,
            _maxChangeBps: 0
        });

        bytes32 reporterRole = keccak256(abi.encode(address(strategy), OFFCHAIN_REPORTER));
        bytes32 managerRole = keccak256(abi.encode(address(strategy), OFFCHAIN_MANAGER));
        vm.startPrank(owner);
        roleManager.grantRole(reporterRole, reporter);
        roleManager.grantRole(managerRole, manager);
        vm.stopPrank();

        vm.startPrank(governance);
        strategyManager.addStrategy(address(strategy), 2 /* OFFCHAIN_NAV */, 0);
        strategyManager.increaseAbsoluteCap(abi.encode(address(strategy), address(underlyingToken)), type(uint128).max);
        strategyManager.increaseRelativeCap(abi.encode(address(strategy), address(underlyingToken)), WAD);
        // Let the share price track NAV in both directions (no rise throttling).
        vault.setMaxRate(MAX_MAX_RATE);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        underlyingToken.mint(who, amount);
        vm.startPrank(who);
        underlyingToken.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// forge-config: default.isolate = true
    function testStaleNAVCannotBeLockedAtRequest() public {
        uint256 deposit = 1_000e18;

        // 1. Two equal LPs enter while everything is healthy. 2000 total assets, ~1:1 share price.
        uint256 attackerShares = _deposit(attacker, deposit);
        uint256 victimShares = _deposit(victim, deposit);
        assertEq(vault.totalAssets(), 2 * deposit, "healthy total = both deposits");

        // 2. Slightly more than half is deployed so a full attacker exit cannot use the immediate path.
        uint256 deployed = deposit + 1;
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deployed);
        vm.prank(manager);
        strategy.deployToCustodian(deployed);
        vm.prank(reporter);
        strategy.report(deployed, 0, 0, keccak256("confirm"), "ipfs://confirm");

        assertEq(vault.totalAssets(), 2 * deposit, "idle + reported NAV");
        assertEq(underlyingToken.balanceOf(address(vault)), deposit - 1, "idle is below full exit value");

        // 3. The custodian loses the ENTIRE offchain position, but the reporter has not (yet) reported it.
        //    Onchain, reportedAssets is still `deposit`; the loss is invisible to the vault.
        vm.prank(custodian);
        underlyingToken.transfer(blackhole, deployed);
        assertEq(underlyingToken.balanceOf(custodian), 0, "offchain capital is gone");

        // 4. Time passes; the mark goes stale. totalAssets() STILL shows the inflated 2000.
        skip(1 days + 1);
        assertTrue(strategy.isStale(), "offchain mark is stale");
        assertEq(vault.totalAssets(), 2 * deposit, "stale keeps the inflated NAV");

        // 5a. CONTROL: the entry gate blocks new deposits/mints while stale.
        underlyingToken.mint(attacker, 1e18);
        vm.startPrank(attacker);
        underlyingToken.approve(address(vault), 1e18);
        vm.expectRevert(ErrorsLib.StaleOffchainStrategy.selector);
        vault.deposit(1e18, attacker);
        vm.stopPrank();

        // 5b. Redeem only escrows shares. The stale request-time estimate is not locked in.
        vm.prank(attacker);
        uint256 staleEstimate = vault.redeem(attackerShares, attacker, attacker);
        assertEq(vault.balanceOf(attacker), 0, "attacker shares escrowed");
        assertEq(vault.balanceOf(address(vault)), attackerShares, "vault holds pending shares");
        assertEq(vault.claimableAssets(attacker), 0, "request is not priced yet");

        address[] memory receivers = new address[](1);
        receivers[0] = attacker;
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.StaleOffchainStrategy.selector);
        vault.fulfillWithdrawal(receivers);

        // 6. The reporter marks the loss. Fulfillment now prices both LPs against the same fresh NAV.
        vm.roll(block.number + 1);
        vm.prank(reporter);
        strategy.report(0, 0, 0, keccak256("truth"), "ipfs://truth");
        vm.prank(allocator);
        vault.fulfillWithdrawal(receivers);
        uint256 attackerGot = vault.claim(attacker);
        uint256 victimValue = vault.convertToAssets(victimShares);

        // ── Fair benchmark ────────────────────────────────────────────────────────────
        // Real value after the loss is the remaining idle balance, split between two equal LPs.
        uint256 fairShare = (deposit - 1) / 2;

        emit log_named_decimal_uint("stale estimate   ", staleEstimate, 18);
        emit log_named_decimal_uint("attacker claimed ", attackerGot, 18);
        emit log_named_decimal_uint("fair share       ", fairShare, 18);
        emit log_named_decimal_uint("victim value     ", victimValue, 18);

        assertApproxEqRel(attackerGot, fairShare, 0.01e18, "requester receives fresh-NAV fair share");
        assertApproxEqRel(victimValue, fairShare, 0.01e18, "remaining LP bears the same loss");
    }
}
