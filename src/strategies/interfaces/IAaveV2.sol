// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

interface IAaveV2 {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAaveV2AToken {
    function balanceOf(address account) external view returns (uint256);
}
