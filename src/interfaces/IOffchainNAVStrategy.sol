// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity >=0.5.0;

import {IStrategy} from "./IStrategy.sol";

/// @dev Minimal external surface for an offchain/RWA strategy. View functions backed by the strategy's
/// internal balance sheet (reportedAssets, isStale, reportHash, …) are accessed directly on the contract
/// to avoid duplicating signatures with the OffchainBalanceSheet base.
interface IOffchainNAVStrategy is IStrategy {
    // Identity
    function vault() external view returns (address);
    function asset() external view returns (address);

    // Reporter-only NAV update (single NAV input path; reflected via accrueInterest, smoothed by maxRate).
    function report(
        uint256 newReportedAssets,
        uint256 newReportedAvailableLiquidity,
        bytes32 newReportHash,
        string calldata newReportURI
    ) external;

    /// @notice Atomically pulls returned capital from the custodian and reconciles the offchain book.
    function returnCapital(uint256 assets) external;
}
