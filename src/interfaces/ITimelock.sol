// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

interface ITimelock {
    function owner() external view returns (address);
    function curator() external view returns (address);
    function isSentinel(address account) external view returns (bool);
    function isTarget(address target) external view returns (bool);
    function timelock(address target, bytes4 selector) external view returns (uint256);
    function abdicated(address target, bytes4 selector) external view returns (bool);
    function executableAt(address target, bytes memory data) external view returns (uint256);

    function setOwner(address newOwner) external;
    function setCurator(address newCurator) external;
    function setIsSentinel(address account, bool newIsSentinel) external;
    function setIsTarget(address target, bool allowed) external;
    function setTimelock(address target, bytes4 selector, uint256 newDuration) external;
    function setAbdicated(address target, bytes4 selector, bool newAbdicated) external;

    function schedule(address target, bytes memory data) external;
    function revoke(address target, bytes memory data) external;
    function execute(address target, bytes memory data) external returns (bytes memory returnData);
}
