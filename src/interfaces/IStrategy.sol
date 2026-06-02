// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity >=0.5.0;

interface IStrategy {
    /// @dev Returns the market' ids and the change in assets on this market.
    function allocate(bytes calldata data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);

    /// @dev Returns the market' ids and the change in assets on this market.
    function deallocate(bytes calldata data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);

    /// @dev Returns the current value of the investments of the strategy (in underlying asset).
    function realAssets() external view returns (uint256 assets);

    function totalAssets() external view returns (uint256);
    function availableLiquidity() external view returns (uint256);
}
