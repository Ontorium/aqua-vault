// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {IGovernanceTimelock} from "./interfaces/IGovernanceTimelock.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

contract GovernanceTimelock is IGovernanceTimelock {
    address public owner;
    address public curator;

    mapping(address account => bool) public isSentinel;
    mapping(address target => bool) public isTarget;
    mapping(address target => mapping(bytes4 selector => uint256 duration)) public timelock;
    mapping(address target => mapping(bytes4 selector => bool isDisabled)) public abdicated;
    mapping(address target => mapping(bytes data => uint256 executableAt)) public executableAt;

    modifier onlyOwner() {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        _;
    }

    modifier onlyCurator() {
        require(msg.sender == curator, ErrorsLib.Unauthorized());
        _;
    }

    modifier onlyCuratorOrSentinel() {
        require(msg.sender == curator || isSentinel[msg.sender], ErrorsLib.Unauthorized());
        _;
    }

    constructor(address _owner, address _curator) {
        require(_owner != address(0), ErrorsLib.ZeroAddress());
        require(_curator != address(0), ErrorsLib.ZeroAddress());

        owner = _owner;
        curator = _curator;

        emit EventsLib.SetOwner(_owner);
        emit EventsLib.SetCurator(_curator);
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), ErrorsLib.ZeroAddress());
        owner = newOwner;
        emit EventsLib.SetOwner(newOwner);
    }

    function setCurator(address newCurator) external onlyOwner {
        require(newCurator != address(0), ErrorsLib.ZeroAddress());
        curator = newCurator;
        emit EventsLib.SetCurator(newCurator);
    }

    function setIsSentinel(address account, bool newIsSentinel) external onlyOwner {
        isSentinel[account] = newIsSentinel;
        emit EventsLib.SetIsSentinel(account, newIsSentinel);
    }

    function setIsTarget(address target, bool allowed) external onlyOwner {
        require(target != address(0), ErrorsLib.ZeroAddress());
        if (allowed) require(target.code.length != 0, ErrorsLib.NoCode());

        isTarget[target] = allowed;
        emit EventsLib.SetGovernanceTarget(target, allowed);
    }

    function setTimelock(address target, bytes4 selector, uint256 newDuration) external onlyOwner {
        require(isTarget[target], ErrorsLib.InvalidTarget());
        timelock[target][selector] = newDuration;
        emit EventsLib.SetGovernanceTimelock(target, selector, newDuration);
    }

    function setAbdicated(address target, bytes4 selector, bool newAbdicated) external onlyOwner {
        require(isTarget[target], ErrorsLib.InvalidTarget());
        abdicated[target][selector] = newAbdicated;
        emit EventsLib.SetGovernanceAbdicated(target, selector, newAbdicated);
    }

    function schedule(address target, bytes calldata data) external onlyCurator {
        require(isTarget[target], ErrorsLib.InvalidTarget());
        require(executableAt[target][data] == 0, ErrorsLib.DataAlreadyPending());

        bytes4 selector = bytes4(data);
        executableAt[target][data] = block.timestamp + timelock[target][selector];
        emit EventsLib.GovernanceSubmit(target, selector, data, executableAt[target][data]);
    }

    function revoke(address target, bytes calldata data) external onlyCuratorOrSentinel {
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
