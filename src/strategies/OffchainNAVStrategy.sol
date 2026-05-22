// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IOffchainNAVStrategy} from "../interfaces/IOffchainNAVStrategy.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @notice Minimal offchain/RWA strategy reporter.
/// @dev This contract does not move assets to offchain by itself. It only reports NAV and immediately available cash.
///      The actual offchain custody process should be controlled by multisig/legal/custodian procedures.
contract OffchainNAVStrategy is IOffchainNAVStrategy {
    address public immutable vault;
    address public immutable asset;

    address public reporter;
    address public custodian;

    uint256 public reportedAssets;
    uint256 public reportedAvailableLiquidity;
    uint256 public maxChangeBps;
    uint256 public stalePeriod;
    uint64 public lastReportTime;
    bytes32 public reportHash;
    string public reportURI;

    event SetReporter(address indexed reporter);
    event SetCustodian(address indexed custodian);
    event SetMaxChangeBps(uint256 maxChangeBps);
    event SetStalePeriod(uint256 stalePeriod);
    event Report(uint256 assets, uint256 availableLiquidity, bytes32 reportHash, string reportURI, uint64 timestamp);

    modifier onlyVault() {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        _;
    }

    modifier onlyReporter() {
        require(msg.sender == reporter, ErrorsLib.Unauthorized());
        _;
    }

    constructor(
        address _vault,
        address _asset,
        address _reporter,
        address _custodian,
        uint256 _stalePeriod,
        uint256 _maxChangeBps
    ) {
        require(_vault != address(0), ErrorsLib.ZeroAddress());
        require(_asset != address(0), ErrorsLib.ZeroAddress());
        require(_reporter != address(0), ErrorsLib.ZeroAddress());

        vault = _vault;
        asset = _asset;
        reporter = _reporter;
        custodian = _custodian;
        stalePeriod = _stalePeriod;
        maxChangeBps = _maxChangeBps;
    }

    function setReporter(address newReporter) external onlyVault {
        require(newReporter != address(0), ErrorsLib.ZeroAddress());
        reporter = newReporter;
        emit SetReporter(newReporter);
    }

    function setCustodian(address newCustodian) external onlyVault {
        custodian = newCustodian;
        emit SetCustodian(newCustodian);
    }

    function setMaxChangeBps(uint256 newMaxChangeBps) external onlyVault {
        maxChangeBps = newMaxChangeBps;
        emit SetMaxChangeBps(newMaxChangeBps);
    }

    function setStalePeriod(uint256 newStalePeriod) external onlyVault {
        stalePeriod = newStalePeriod;
        emit SetStalePeriod(newStalePeriod);
    }

    function report(uint256 newAssets, bytes32 newReportHash, string calldata newReportURI) external onlyReporter {
        _report(newAssets, 0, newReportHash, newReportURI);
    }

    function report(uint256 newAssets, uint256 availableLiquidity_, bytes32 newReportHash, string calldata newReportURI)
        external
        onlyReporter
    {
        _report(newAssets, availableLiquidity_, newReportHash, newReportURI);
    }

    function realAssets() external view returns (uint256) {
        return _totalAssets();
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets();
    }

    function availableLiquidity() external view returns (uint256) {
        if (isStale()) return 0;
        return reportedAvailableLiquidity;
    }

    function isStale() public view returns (bool) {
        if (lastReportTime == 0) return true;
        return stalePeriod != 0 && block.timestamp > uint256(lastReportTime) + stalePeriod;
    }

    /// @dev Allocation means the Vault transferred assets to this strategy.
    ///      If assets must leave the strategy to an offchain custodian, that should be a separate, permissioned flow.
    function allocate(bytes memory, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        ids = new bytes32[](1);
        ids[0] = keccak256(abi.encode(address(this), asset));
        change = int256(assets);
    }

    /// @dev Deallocation only records accounting and expects the strategy to approve the Vault for `assets`.
    ///      For a production RWA strategy, replace this with a request/settlement flow.
    function deallocate(bytes memory, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        ids = new bytes32[](1);
        ids[0] = keccak256(abi.encode(address(this), asset));
        change = -int256(assets);

        // The Vault pulls `assets` with safeTransferFrom after this call.
        (bool success, bytes memory result) =
            asset.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), vault, assets));
        require(success && (result.length == 0 || abi.decode(result, (bool))), "APPROVE_FAILED");
    }

    function _report(uint256 newAssets, uint256 availableLiquidity_, bytes32 newReportHash, string calldata newReportURI)
        internal
    {
        require(availableLiquidity_ <= newAssets, "AVAILABLE_GT_ASSETS");

        uint256 oldAssets = reportedAssets;
        if (lastReportTime != 0 && maxChangeBps != 0 && oldAssets != 0) {
            uint256 delta = newAssets > oldAssets ? newAssets - oldAssets : oldAssets - newAssets;
            require(delta * 10_000 <= oldAssets * maxChangeBps, "MAX_CHANGE_EXCEEDED");
        }

        reportedAssets = newAssets;
        reportedAvailableLiquidity = availableLiquidity_;
        reportHash = newReportHash;
        reportURI = newReportURI;
        lastReportTime = uint64(block.timestamp);

        emit Report(newAssets, availableLiquidity_, newReportHash, newReportURI, uint64(block.timestamp));
    }

    function _totalAssets() internal view returns (uint256) {
        if (isStale()) return 0;
        return reportedAssets;
    }
}
