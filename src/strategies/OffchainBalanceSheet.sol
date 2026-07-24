// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";

/// @notice Internal accounting for an offchain strategy.
/// @dev Intended to be inherited by OffchainNAVStrategy.
abstract contract OffchainBalanceSheet {
    uint256 internal constant BPS = 10_000;

    struct Position {
        // Principal allocated by the vault.
        uint128 allocatedPrincipal;
        // Principal deployed to the offchain custodian.
        uint128 deployedPrincipal;
        // Reported offchain NAV, excluding onchain idle assets.
        uint128 reportedAssets;
        // Reported offchain liquidity, excluding onchain idle assets.
        uint128 reportedAvailableLiquidity;
        uint64 lastReportTime;
        uint64 lastReportBlock;
        uint64 stalePeriod;
        bytes32 reportHash;
    }

    Position internal _position;
    string internal _reportURI;

    function allocatedPrincipal() public view returns (uint256) {
        return _position.allocatedPrincipal;
    }

    function deployedPrincipal() public view returns (uint256) {
        return _position.deployedPrincipal;
    }

    function reportedAssets() public view returns (uint256) {
        return _position.reportedAssets;
    }

    function reportedAvailableLiquidity() public view returns (uint256) {
        return _position.reportedAvailableLiquidity;
    }

    function lastReportTime() public view returns (uint256) {
        return _position.lastReportTime;
    }

    function lastReportBlock() public view returns (uint256) {
        return _position.lastReportBlock;
    }

    function stalePeriod() public view returns (uint256) {
        return _position.stalePeriod;
    }

    function reportHash() public view returns (bytes32) {
        return _position.reportHash;
    }

    function reportURI() public view returns (string memory) {
        return _reportURI;
    }

    function isStale() public view returns (bool) {
        if (_position.lastReportTime == 0) return true;
        return _position.stalePeriod != 0 && block.timestamp > uint256(_position.lastReportTime) + _position.stalePeriod;
    }

    function _setStalePeriod(uint256 newStalePeriod) internal {
        _position.stalePeriod = _toUint64(newStalePeriod);
        emit EventsLib.StalePeriodSet(newStalePeriod);
    }

    function _recordAllocation(uint256 assets) internal {
        _position.allocatedPrincipal = _toUint128(uint256(_position.allocatedPrincipal) + assets);
        emit EventsLib.StrategyAllocated(assets);
    }

    function _recordDeallocation(uint256 assets) internal {
        uint256 current = _position.allocatedPrincipal;
        // Realized profit may make the onchain balance larger than the principal originally
        // allocated by the vault. The strategy's actual token balance limits deallocation;
        // principal accounting therefore floors at zero when principal plus profit is returned.
        _position.allocatedPrincipal = assets >= current ? 0 : _toUint128(current - assets);
        emit EventsLib.StrategyDeallocated(assets);
    }

    /// @dev Moves idle onchain assets into offchain book value.
    function _recordCapitalDeployed(uint256 assets, address destination) internal {
        _position.deployedPrincipal = _toUint128(uint256(_position.deployedPrincipal) + assets);
        _position.reportedAssets = _toUint128(uint256(_position.reportedAssets) + assets);
        emit EventsLib.CapitalDeployed(assets, destination);
    }

    /// @dev Atomically moves value from the offchain book into onchain idle accounting.
    /// The caller transfers the underlying before invoking this hook in the same transaction.
    function _recordCapitalReturned(uint256 assets) internal {
        uint256 reported = _position.reportedAssets;
        uint256 available = _position.reportedAvailableLiquidity;
        require(assets <= reported, ErrorsLib.RequestExceedsReportedAssets());
        require(assets <= available, ErrorsLib.RequestExceedsAvailableLiquidity());

        _position.reportedAssets = _toUint128(reported - assets);
        _position.reportedAvailableLiquidity = _toUint128(available - assets);

        uint256 deployed = _position.deployedPrincipal;
        _position.deployedPrincipal = assets >= deployed ? 0 : _toUint128(deployed - assets);

        emit EventsLib.CapitalReturned(assets);
    }

    function _recordNAVReport(
        uint256 newReportedAssets,
        uint256 newReportedAvailableLiquidity,
        bytes32 newReportHash,
        string calldata newReportURI,
        uint256 maxChangeBps
    ) internal {
        if (_position.lastReportTime != 0 && _position.lastReportBlock == block.number) {
            revert ErrorsLib.ReportAlreadySubmittedThisBlock();
        }
        require(newReportedAvailableLiquidity <= newReportedAssets, ErrorsLib.AvailableExceedsReportedAssets());

        uint256 oldOffchainValue = _position.reportedAssets;
        uint256 newOffchainValue = newReportedAssets;

        // Cap only upward marks. Losses must remain reportable in full so an outdated, inflated NAV
        // cannot persist merely because the realized loss exceeds the configured circuit breaker.
        if (
            _position.lastReportTime != 0 && maxChangeBps != 0 && oldOffchainValue != 0
                && newOffchainValue > oldOffchainValue
        ) {
            uint256 gain = newOffchainValue - oldOffchainValue;
            require(gain * BPS <= oldOffchainValue * maxChangeBps, ErrorsLib.MaxChangeExceeded());
        }

        _position.reportedAssets = _toUint128(newReportedAssets);
        _position.reportedAvailableLiquidity = _toUint128(newReportedAvailableLiquidity);
        _position.reportHash = newReportHash;
        _position.lastReportTime = uint64(block.timestamp);
        _position.lastReportBlock = _toUint64(block.number);
        _reportURI = newReportURI;

        emit EventsLib.NAVReported(
            newReportedAssets,
            newReportedAvailableLiquidity,
            newReportHash,
            newReportURI,
            uint64(block.timestamp)
        );
    }

    function _toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, ErrorsLib.CastOverflow());
        return uint128(value);
    }

    function _toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, ErrorsLib.CastOverflow());
        return uint64(value);
    }
}
