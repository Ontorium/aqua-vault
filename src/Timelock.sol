// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.28;

import {ITimelock} from "./interfaces/ITimelock.sol";
import {AccessManaged} from "./AccessManaged.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/// @notice Delay-based execution wrapper. Holds privileged roles (e.g. GOVERNANCE_ROLE) on behalf of a
/// curator: the curator schedules a call, anyone may execute after the configured delay.
/// @dev Role membership (curator/sentinel/governance) lives in RoleManager, NOT here.
contract Timelock is ITimelock, AccessManaged {
    mapping(address target => bool) public isTarget;
    mapping(address target => mapping(bytes4 selector => uint256 duration)) public timelock;
    mapping(address target => mapping(bytes4 selector => bool isDisabled)) public abdicated;
    mapping(address target => mapping(bytes data => uint256 executableAt)) public executableAt;

    /// @dev The Timelock is its own role scope: its governance crew (GOVERNANCE/CURATOR/SENTINEL who
    /// configure targets / schedule / revoke) are namespaced under the Timelock's own address. It governs
    /// a vault by separately holding that vault's `scoped(vault, GOVERNANCE)`.
    constructor(address _roleManager) AccessManaged(_roleManager, address(this)) {
        // Register self as a target so `decreaseTimelock` can be routed through schedule/execute and pick up
        // the self-referential delay computed in `schedule`. Every other self-function is GOVERNANCE-gated,
        // so `execute` (msg.sender == this, holding no roles) can only ever reach `decreaseTimelock`.
        isTarget[address(this)] = true;
    }

    function setIsTarget(address target, bool allowed) external onlyRole(GOVERNANCE_ROLE) {
        require(target != address(0), ErrorsLib.ZeroAddress());
        if (allowed) require(target.code.length != 0, ErrorsLib.NoCode());

        isTarget[target] = allowed;
        emit EventsLib.SetGovernanceTarget(target, allowed);
    }

    /// @notice Raise a (target, selector) delay. Immediate — strengthening protection is always safe.
    /// @dev Equal `newDuration` is allowed (idempotent); lowering must go through the delayed path.
    function increaseTimelock(address target, bytes4 selector, uint256 newDuration) external onlyRole(GOVERNANCE_ROLE) {
        require(isTarget[target], ErrorsLib.InvalidTarget());
        require(newDuration >= timelock[target][selector], ErrorsLib.TimelockNotIncreasing());
        timelock[target][selector] = newDuration;
        emit EventsLib.SetTimelock(target, selector, newDuration);
    }

    /// @notice Reduce a (target, selector) delay. Reachable ONLY via `execute` (self-call), and `schedule`
    /// delays it by the *current* timelock of the same (target, selector) — so a strong timelock can never
    /// be weakened faster than itself. Anti-rug against a compromised key.
    /// @dev Flow: curator `schedule(this, abi.encodeCall(decreaseTimelock, (target, selector, newDuration)))`
    /// → wait the current delay → anyone `execute(this, sameData)`. Cancel with `revoke`.
    function decreaseTimelock(address target, bytes4 selector, uint256 newDuration) external {
        require(msg.sender == address(this), ErrorsLib.Unauthorized());
        require(newDuration < timelock[target][selector], ErrorsLib.TimelockNotDecreasing());
        timelock[target][selector] = newDuration;
        emit EventsLib.SetTimelock(target, selector, newDuration);
    }

    function setAbdicated(address target, bytes4 selector, bool newAbdicated) external onlyRole(GOVERNANCE_ROLE) {
        require(isTarget[target], ErrorsLib.InvalidTarget());
        abdicated[target][selector] = newAbdicated;
        emit EventsLib.SetGovernanceAbdicated(target, selector, newAbdicated);
    }

    function schedule(address target, bytes calldata data) external onlyRole(CURATOR_ROLE) {
        require(isTarget[target], ErrorsLib.InvalidTarget());
        require(executableAt[target][data] == 0, ErrorsLib.DataAlreadyPending());

        bytes4 selector = bytes4(data);
        uint256 delay;
        if (target == address(this) && selector == this.decreaseTimelock.selector) {
            // Self-referential: reducing a (innerTarget, innerSelector) delay waits that delay's CURRENT value.
            (address innerTarget, bytes4 innerSelector,) = abi.decode(data[4:], (address, bytes4, uint256));
            delay = timelock[innerTarget][innerSelector];
        } else {
            delay = timelock[target][selector];
        }
        executableAt[target][data] = block.timestamp + delay;
        emit EventsLib.GovernanceSubmit(target, selector, data, executableAt[target][data]);
    }

    function revoke(address target, bytes calldata data) external {
        _requireAnyRole(CURATOR_ROLE, SENTINEL_ROLE);
        require(executableAt[target][data] != 0, ErrorsLib.DataNotTimelocked());

        delete executableAt[target][data];
        emit EventsLib.GovernanceRevoke(msg.sender, target, bytes4(data), data);
    }

    function execute(address target, bytes calldata data) external returns (bytes memory returnData) {
        require(isTarget[target], ErrorsLib.InvalidTarget());

        bytes4 selector = bytes4(data);
        uint256 readyAt = executableAt[target][data];

        require(readyAt != 0, ErrorsLib.DataNotTimelocked());
        require(block.timestamp >= readyAt, ErrorsLib.TimelockNotExpired());
        require(!abdicated[target][selector], ErrorsLib.Abdicated());

        delete executableAt[target][data];
        emit EventsLib.GovernanceAccept(target, selector, data);

        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }

        return result;
    }
}
