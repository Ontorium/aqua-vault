// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Minimal Aave V3 Pool surface used by AaveV3Strategy.
/// @dev V3 renamed V2's `deposit` to `supply` (same params). `withdraw` is unchanged.
interface IAaveV3 {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAaveV3AToken {
    function balanceOf(address account) external view returns (uint256);
}
