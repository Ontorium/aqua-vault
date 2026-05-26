// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";

/// @notice Internal accounting module for an offchain/RWA strategy.
/// @dev This contract does not hold assets. It is intended to be inherited by OffchainNAVStrategy.
abstract contract OffchainBalanceSheet {
    uint256 internal constant BPS = 10_000;

    struct Position {
        // Current principal allocated from the Vault to this strategy.
        uint128 allocatedPrincipal;
        // Principal currently sent from this strategy to an offchain custodian/manager.
        uint128 deployedPrincipal;
        // Offchain NAV, excluding ERC20 assets currently held by this strategy.
        uint128 reportedAssets;
        // Offchain liquidity that can be requested quickly, excluding ERC20 assets currently held by this strategy.
        uint128 reportedAvailableLiquidity;
        // Requested return amount not yet received by this strategy.
        uint128 pendingReceivable;
        uint64 lastReportTime;
        uint64 stalePeriod;
        // Minimum seconds between successive NAV reports (anti-spam / rate limit).
        uint64 minReportInterval;
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

    function pendingReceivable() public view returns (uint256) {
        return _position.pendingReceivable;
    }

    function lastReportTime() public view returns (uint256) {
        return _position.lastReportTime;
    }

    function stalePeriod() public view returns (uint256) {
        return _position.stalePeriod;
    }

    function minReportInterval() public view returns (uint256) {
        return _position.minReportInterval;
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

    function _setMinReportInterval(uint256 newMinReportInterval) internal {
        _position.minReportInterval = _toUint64(newMinReportInterval);
        emit EventsLib.SetMinReportInterval(newMinReportInterval);
    }

    function _recordAllocation(uint256 assets) internal {
        _position.allocatedPrincipal = _toUint128(uint256(_position.allocatedPrincipal) + assets);
        emit EventsLib.StrategyAllocated(assets);
    }

    function _recordDeallocation(uint256 assets) internal {
        uint256 current = _position.allocatedPrincipal;
        require(assets <= current, ErrorsLib.DeallocationExceedsAllocation());
        _position.allocatedPrincipal = uint128(current - assets);
        emit EventsLib.StrategyDeallocated(assets);
    }

    /// @dev Records movement from onchain idle cash to offchain book value.
    ///      This keeps realAssets stable immediately after funds are sent out.
    function _recordCapitalDeployed(uint256 assets, address destination) internal {
        _position.deployedPrincipal = _toUint128(uint256(_position.deployedPrincipal) + assets);
        _position.reportedAssets = _toUint128(uint256(_position.reportedAssets) + assets);
        emit EventsLib.CapitalDeployed(assets, destination);
    }

    /// @dev Moves value from reported offchain assets to pending receivable.
    function _recordReturnRequested(uint256 assets) internal {
        require(assets <= _position.reportedAssets, ErrorsLib.RequestExceedsReportedAssets());
        require(assets <= _position.reportedAvailableLiquidity, ErrorsLib.RequestExceedsAvailableLiquidity());

        _position.reportedAssets = uint128(uint256(_position.reportedAssets) - assets);
        _position.reportedAvailableLiquidity = uint128(uint256(_position.reportedAvailableLiquidity) - assets);
        _position.pendingReceivable = _toUint128(uint256(_position.pendingReceivable) + assets);

        emit EventsLib.ReturnRequested(assets);
    }

    /// @dev Records assets that have arrived back onchain.
    ///      It first clears pending receivable, then reduces reported assets if assets arrived without a prior request.
    function _recordCapitalReturned(uint256 assets) internal {
        uint256 remaining = assets;

        uint256 receivable = _position.pendingReceivable;
        if (remaining >= receivable) {
            _position.pendingReceivable = 0;
            remaining -= receivable;
        } else {
            _position.pendingReceivable = uint128(receivable - remaining);
            remaining = 0;
        }

        if (remaining != 0) {
            uint256 reported = _position.reportedAssets;
            if (remaining >= reported) {
                _position.reportedAssets = 0;
                remaining -= reported;
            } else {
                _position.reportedAssets = uint128(reported - remaining);
                remaining = 0;
            }
        }

        uint256 deployed = _position.deployedPrincipal;
        if (assets >= deployed) {
            _position.deployedPrincipal = 0;
        } else {
            _position.deployedPrincipal = uint128(deployed - assets);
        }

        emit EventsLib.CapitalReturned(assets);
    }

    function _recordNAVReport(
        uint256 newReportedAssets,
        uint256 newReportedAvailableLiquidity,
        uint256 newPendingReceivable,
        bytes32 newReportHash,
        string calldata newReportURI,
        uint256 maxChangeBps
    ) internal {
        require(newReportedAvailableLiquidity <= newReportedAssets, ErrorsLib.AvailableExceedsReportedAssets());

        // Rate-limit consecutive NAV updates.
        if (_position.lastReportTime != 0 && _position.minReportInterval != 0) {
            require(
                block.timestamp >= uint256(_position.lastReportTime) + uint256(_position.minReportInterval),
                ErrorsLib.ReportTooSoon()
            );
        }

        uint256 oldOffchainValue = uint256(_position.reportedAssets) + uint256(_position.pendingReceivable);
        uint256 newOffchainValue = newReportedAssets + newPendingReceivable;

        if (_position.lastReportTime != 0 && maxChangeBps != 0 && oldOffchainValue != 0) {
            uint256 delta = newOffchainValue > oldOffchainValue
                ? newOffchainValue - oldOffchainValue
                : oldOffchainValue - newOffchainValue;

            require(delta * BPS <= oldOffchainValue * maxChangeBps, ErrorsLib.MaxChangeExceeded());
        }

        _position.reportedAssets = _toUint128(newReportedAssets);
        _position.reportedAvailableLiquidity = _toUint128(newReportedAvailableLiquidity);
        _position.pendingReceivable = _toUint128(newPendingReceivable);
        _position.reportHash = newReportHash;
        _position.lastReportTime = uint64(block.timestamp);
        _reportURI = newReportURI;

        emit EventsLib.NAVReported(
            newReportedAssets,
            newReportedAvailableLiquidity,
            newPendingReceivable,
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
