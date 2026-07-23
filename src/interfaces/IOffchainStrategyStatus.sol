// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity >=0.5.0;

/// @dev Minimal read-only surface the StrategyManager needs to reason about stale offchain exposure
/// without depending on the full strategy implementation.
interface IOffchainStrategyStatus {
    function deployedPrincipal() external view returns (uint256);
    function reportedAssets() external view returns (uint256);
    function isStale() external view returns (bool);
}
