// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity >=0.5.0;

import {IStrategy} from "./IStrategy.sol";

interface IOffchainNAVStrategy is IStrategy {
    // Identity
    function vault() external view returns (address);
    function asset() external view returns (address);

    // Reporter / custodian roles
    function reporter() external view returns (address);
    function custodian() external view returns (address);

    // Reported state
    function reportedAssets() external view returns (uint256);
    function reportedAvailableLiquidity() external view returns (uint256);
    function maxChangeBps() external view returns (uint256);
    function stalePeriod() external view returns (uint256);
    function lastReportTime() external view returns (uint64);
    function reportHash() external view returns (bytes32);
    function reportURI() external view returns (string memory);
    function isStale() external view returns (bool);

    // Vault-only admin
    function setReporter(address newReporter) external;
    function setCustodian(address newCustodian) external;
    function setMaxChangeBps(uint256 newMaxChangeBps) external;
    function setStalePeriod(uint256 newStalePeriod) external;

    // Reporter-only updates
    function report(uint256 newAssets, bytes32 newReportHash, string calldata newReportURI) external;
    function report(
        uint256 newAssets,
        uint256 availableLiquidity,
        bytes32 newReportHash,
        string calldata newReportURI
    ) external;
}
