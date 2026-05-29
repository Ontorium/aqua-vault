// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

/// @notice Exercises the governance-gated setters on the Vault and the role-based access checks.
/// @dev The old submit/timelock/accept dance on the Vault is gone — gating is a single `onlyRole(GOVERNANCE_ROLE)`
/// check. Timelocked execution is covered separately in TimelockTest.
contract SettersTest is BaseTest {
    function testConstructorRoles() public view {
        assertTrue(roleManager.hasRole(roleManager.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(roleManager.hasRole(roleManager.getScopedRole(address(vault), "GOVERNANCE_ROLE"), governance));
        assertTrue(roleManager.hasRole(roleManager.getScopedRole(address(vault), "GOVERNANCE_ROLE"), address(timelock)));
        assertTrue(roleManager.hasRole(roleManager.getScopedRole(address(vault), "CURATOR_ROLE"), curator));
        assertTrue(roleManager.hasRole(roleManager.getScopedRole(address(vault), "SENTINEL_ROLE"), sentinel));
        assertTrue(roleManager.hasRole(roleManager.getScopedRole(address(vault), "ALLOCATOR_ROLE"), allocator));
    }

    /* NAME / SYMBOL */

    function testSetName(address rdm, string memory newName) public {
        vm.assume(rdm != governance && rdm != address(timelock));

        assertEq(vault.name(), "");

        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        vault.setName(newName);

        vm.prank(governance);
        vm.expectEmit();
        emit EventsLib.SetName(newName);
        vault.setName(newName);
        assertEq(vault.name(), newName);
    }

    function testSetSymbol(address rdm, string memory newSymbol) public {
        vm.assume(rdm != governance && rdm != address(timelock));

        assertEq(vault.symbol(), "");

        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        vault.setSymbol(newSymbol);

        vm.prank(governance);
        vm.expectEmit();
        emit EventsLib.SetSymbol(newSymbol);
        vault.setSymbol(newSymbol);
        assertEq(vault.symbol(), newSymbol);
    }

    /* GATES */

    function testSetReceiveSharesGate(address rdm, address newGate) public {
        vm.assume(rdm != governance && rdm != address(timelock));

        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        vault.setReceiveSharesGate(newGate);

        vm.prank(governance);
        vm.expectEmit();
        emit EventsLib.SetReceiveSharesGate(newGate);
        vault.setReceiveSharesGate(newGate);
        assertEq(vault.receiveSharesGate(), newGate);
    }

    function testSetSendSharesGate(address rdm, address newGate) public {
        vm.assume(rdm != governance && rdm != address(timelock));

        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        vault.setSendSharesGate(newGate);

        vm.prank(governance);
        vault.setSendSharesGate(newGate);
        assertEq(vault.sendSharesGate(), newGate);
    }

    function testSetReceiveAssetsGate(address rdm, address newGate) public {
        vm.assume(rdm != governance && rdm != address(timelock));

        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        vault.setReceiveAssetsGate(newGate);

        vm.prank(governance);
        vault.setReceiveAssetsGate(newGate);
        assertEq(vault.receiveAssetsGate(), newGate);
    }

    function testSetSendAssetsGate(address rdm, address newGate) public {
        vm.assume(rdm != governance && rdm != address(timelock));

        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        vault.setSendAssetsGate(newGate);

        vm.prank(governance);
        vault.setSendAssetsGate(newGate);
        assertEq(vault.sendAssetsGate(), newGate);
    }

    /* STRATEGY MANAGER (one-shot during deployment) */

    function testSetStrategyManagerRejectsResetting() public {
        // setUp() created a vault with strategyManager already wired by the factory.
        assertEq(vault.strategyManager(), address(strategyManager));

        // Second attempt must revert because strategyManager is non-zero.
        StrategyManager replacement = new StrategyManager(address(vault), address(underlyingToken), address(roleManager));
        vm.prank(governance);
        vm.expectRevert(ErrorsLib.InvalidStrategyManager.selector);
        vault.setStrategyManager(address(replacement));
    }

    /* PRICE MANAGER */

    function testSetPriceManager(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));

        // Must point at a contract (NoCode check).
        address newPriceManager = address(strategyManager); // any deployed contract works for this test
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        vault.setPriceManager(newPriceManager);

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vault.setPriceManager(address(0));

        vm.prank(governance);
        vm.expectEmit();
        emit EventsLib.SetPriceManager(newPriceManager);
        vault.setPriceManager(newPriceManager);
        assertEq(vault.priceManager(), newPriceManager);
    }

    /* FEES */

    function testSetPerformanceFeeRequiresRecipientFirst(uint256 fee) public {
        fee = bound(fee, 1, MAX_PERFORMANCE_FEE);

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.FeeInvariantBroken.selector);
        vault.setPerformanceFee(fee);

        address recipient = makeAddr("perfRecipient");
        vm.prank(governance);
        vault.setPerformanceFeeRecipient(recipient);

        vm.prank(governance);
        vm.expectEmit();
        emit EventsLib.SetPerformanceFee(fee);
        vault.setPerformanceFee(fee);
        assertEq(vault.performanceFee(), fee);
    }

    function testSetPerformanceFeeTooHigh(uint256 tooHigh) public {
        tooHigh = bound(tooHigh, MAX_PERFORMANCE_FEE + 1, type(uint96).max);

        vm.prank(governance);
        vault.setPerformanceFeeRecipient(makeAddr("perfRecipient"));

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.FeeTooHigh.selector);
        vault.setPerformanceFee(tooHigh);
    }

    function testSetManagementFee(uint256 fee) public {
        fee = bound(fee, 1, MAX_MANAGEMENT_FEE);

        vm.prank(governance);
        vault.setManagementFeeRecipient(makeAddr("mgmtRecipient"));

        vm.prank(governance);
        vm.expectEmit();
        emit EventsLib.SetManagementFee(fee);
        vault.setManagementFee(fee);
        assertEq(vault.managementFee(), fee);
    }

    function testSetDepositFee(uint256 fee) public {
        fee = bound(fee, 1, MAX_DEPOSIT_FEE);

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.FeeInvariantBroken.selector);
        vault.setDepositFee(fee);

        vm.prank(governance);
        vault.setProtocolFeeRecipient(makeAddr("protocolRecipient"));

        vm.prank(governance);
        vault.setDepositFee(fee);
        assertEq(vault.depositFee(), fee);
    }

    function testSetWithdrawalFee(uint256 fee) public {
        fee = bound(fee, 1, MAX_WITHDRAWAL_FEE);

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.FeeInvariantBroken.selector);
        vault.setWithdrawalFee(fee);

        vm.prank(governance);
        vault.setProtocolFeeRecipient(makeAddr("protocolRecipient"));

        vm.prank(governance);
        vault.setWithdrawalFee(fee);
        assertEq(vault.withdrawalFee(), fee);
    }

    function testSetProtocolFeeRecipientCannotZeroOutWithFees() public {
        vm.startPrank(governance);
        vault.setProtocolFeeRecipient(makeAddr("protocolRecipient"));
        vault.setDepositFee(0.01e18);
        vm.expectRevert(ErrorsLib.FeeInvariantBroken.selector);
        vault.setProtocolFeeRecipient(address(0));
        vm.stopPrank();
    }

    /* MAX RATE */

    function testSetMaxRate(uint256 newMaxRate) public {
        newMaxRate = bound(newMaxRate, 0, MAX_MAX_RATE);

        vm.prank(governance);
        vm.expectEmit();
        emit EventsLib.SetMaxRate(newMaxRate);
        vault.setMaxRate(newMaxRate);
        assertEq(vault.maxRate(), newMaxRate);
    }

    function testSetMaxRateTooHighReverts(uint256 tooHigh) public {
        tooHigh = bound(tooHigh, MAX_MAX_RATE + 1, type(uint256).max);
        vm.prank(governance);
        vm.expectRevert(ErrorsLib.MaxRateTooHigh.selector);
        vault.setMaxRate(tooHigh);
    }

    function testSetMaxRateUnauthorized(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        vault.setMaxRate(MAX_MAX_RATE);
    }

    /* PAUSE */

    function testPause() public {
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vault.pause();

        vm.prank(sentinel);
        vm.expectEmit();
        emit EventsLib.Paused(sentinel);
        vault.pause();
        assertTrue(vault.paused());
    }

    function testUnpauseRequiresGovernance(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));

        vm.prank(sentinel);
        vault.pause();

        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vault.unpause();

        vm.prank(governance);
        vm.expectEmit();
        emit EventsLib.Unpaused(governance);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function testPausedBlocksDeposit() public {
        vm.prank(sentinel);
        vault.pause();

        underlyingToken.mint(address(this), 1);
        underlyingToken.approve(address(vault), 1);
        vm.expectRevert(ErrorsLib.Paused.selector);
        vault.deposit(1, address(this));
    }
}
