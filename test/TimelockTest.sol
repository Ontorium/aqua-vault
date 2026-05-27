// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract TimelockTest is BaseTest {
    /// @dev Tiny payload contract Timelock can call into for execute-path tests.
    function _payload(uint256) external pure returns (uint256) {
        return 7;
    }

    function testInitialState() public view {
        // Factory set Timelock as a governance target on... nothing — `isTarget` defaults to false.
        // The factory only deploys the timelock; governance must opt-in targets.
        assertFalse(timelock.isTarget(address(vault)));
        assertEq(timelock.timelock(address(vault), Vault.setName.selector), 0);
        assertFalse(timelock.abdicated(address(vault), Vault.setName.selector));
    }

    function testSetIsTarget(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));

        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        timelock.setIsTarget(address(vault), true);

        // ZeroAddress check.
        vm.prank(governance);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        timelock.setIsTarget(address(0), true);

        // Target must have code when adding.
        address eoa = makeAddr("eoa");
        vm.prank(governance);
        vm.expectRevert(ErrorsLib.NoCode.selector);
        timelock.setIsTarget(eoa, true);

        // Normal path.
        vm.expectEmit();
        emit EventsLib.SetGovernanceTarget(address(vault), true);
        vm.prank(governance);
        timelock.setIsTarget(address(vault), true);
        assertTrue(timelock.isTarget(address(vault)));
    }

    function testScheduleAndExecuteImmediately() public {
        // Make vault a target and set duration 0 so execute is immediate.
        vm.prank(governance);
        timelock.setIsTarget(address(vault), true);

        bytes memory data = abi.encodeCall(Vault.setName, ("aqua"));

        // Curator schedules.
        vm.expectEmit();
        emit EventsLib.GovernanceSubmit(address(vault), Vault.setName.selector, data, block.timestamp);
        vm.prank(curator);
        timelock.schedule(address(vault), data);
        assertEq(timelock.executableAt(address(vault), data), block.timestamp);

        // Anyone executes after the delay (here: immediately).
        timelock.execute(address(vault), data);
        assertEq(vault.name(), "aqua");
        assertEq(timelock.executableAt(address(vault), data), 0, "consumed");
    }

    function testScheduleAndExecuteWithDelay(uint64 delay) public {
        delay = uint64(bound(delay, 1, 365 days));

        vm.startPrank(governance);
        timelock.setIsTarget(address(vault), true);
        timelock.setTimelock(address(vault), Vault.setName.selector, delay);
        vm.stopPrank();

        bytes memory data = abi.encodeCall(Vault.setName, ("aqua"));
        vm.prank(curator);
        timelock.schedule(address(vault), data);

        // Cannot execute before maturity.
        vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
        timelock.execute(address(vault), data);

        skip(delay);
        timelock.execute(address(vault), data);
        assertEq(vault.name(), "aqua");
    }

    function testCannotScheduleNonTarget() public {
        bytes memory data = abi.encodeCall(Vault.setName, ("aqua"));
        vm.expectRevert(ErrorsLib.InvalidTarget.selector);
        vm.prank(curator);
        timelock.schedule(address(vault), data);
    }

    function testScheduleRejectsDuplicate() public {
        vm.prank(governance);
        timelock.setIsTarget(address(vault), true);

        bytes memory data = abi.encodeCall(Vault.setName, ("aqua"));
        vm.prank(curator);
        timelock.schedule(address(vault), data);

        vm.expectRevert(ErrorsLib.DataAlreadyPending.selector);
        vm.prank(curator);
        timelock.schedule(address(vault), data);
    }

    function testRevokeBySentinel() public {
        vm.prank(governance);
        timelock.setIsTarget(address(vault), true);

        bytes memory data = abi.encodeCall(Vault.setName, ("aqua"));
        vm.prank(curator);
        timelock.schedule(address(vault), data);

        vm.expectEmit();
        emit EventsLib.GovernanceRevoke(sentinel, address(vault), Vault.setName.selector, data);
        vm.prank(sentinel);
        timelock.revoke(address(vault), data);
        assertEq(timelock.executableAt(address(vault), data), 0);
    }

    function testRevokeOnNothingReverts() public {
        bytes memory data = abi.encodeCall(Vault.setName, ("aqua"));
        vm.expectRevert(ErrorsLib.DataNotTimelocked.selector);
        vm.prank(sentinel);
        timelock.revoke(address(vault), data);
    }

    function testAbdicateBlocksExecution() public {
        vm.startPrank(governance);
        timelock.setIsTarget(address(vault), true);
        timelock.setAbdicated(address(vault), Vault.setName.selector, true);
        vm.stopPrank();

        bytes memory data = abi.encodeCall(Vault.setName, ("aqua"));
        vm.prank(curator);
        timelock.schedule(address(vault), data);

        vm.expectRevert(ErrorsLib.Abdicated.selector);
        timelock.execute(address(vault), data);
    }

    function testExecuteBubblesUpRevert() public {
        vm.prank(governance);
        timelock.setIsTarget(address(vault), true);

        // setMaxRate with a value above MAX_MAX_RATE must revert inside execute.
        bytes memory data = abi.encodeCall(Vault.setMaxRate, (MAX_MAX_RATE + 1));
        vm.prank(curator);
        timelock.schedule(address(vault), data);

        vm.expectRevert(ErrorsLib.MaxRateTooHigh.selector);
        timelock.execute(address(vault), data);
    }

    function testScheduleRequiresCurator(address rdm) public {
        vm.assume(rdm != curator);
        vm.prank(governance);
        timelock.setIsTarget(address(vault), true);

        bytes memory data = abi.encodeCall(Vault.setName, ("aqua"));
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(rdm);
        timelock.schedule(address(vault), data);
    }
}
