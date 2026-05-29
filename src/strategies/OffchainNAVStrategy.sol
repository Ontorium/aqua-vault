// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IOffchainNAVStrategy} from "../interfaces/IOffchainNAVStrategy.sol";
import {OffchainBalanceSheet} from "./OffchainBalanceSheet.sol";
import {AccessManaged} from "../AccessManaged.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

/// @notice RWA/offchain strategy with its own internal BalanceSheet.
/// @dev The Vault keeps user share accounting. This strategy keeps offchain position accounting.
/// @dev Reporter/manager are NOT stored locally — they are role memberships in the central RoleManager.
///      Per-strategy scoping is achieved with `_scopedRole(OFFCHAIN_REPORTER)` etc., so a reporter for
///      one strategy is NOT automatically a reporter for another.
contract OffchainNAVStrategy is IOffchainNAVStrategy, OffchainBalanceSheet, AccessManaged {
    /// @dev Per-strategy scoped role names. Combined with address(this) via `_scopedRole(...)`.
    bytes32 internal constant OFFCHAIN_REPORTER = keccak256("OFFCHAIN_REPORTER");
    bytes32 internal constant OFFCHAIN_MANAGER = keccak256("OFFCHAIN_MANAGER");

    address public immutable override vault;
    address public immutable override asset;

    address public custodian;
    uint256 public maxChangeBps;

    modifier onlyVault() {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        _;
    }

    modifier onlyManager() {
        require(
            roleManager.hasRole(_scopedRole(OFFCHAIN_MANAGER), msg.sender), ErrorsLib.Unauthorized()
        );
        _;
    }

    modifier onlyReporter() {
        require(
            roleManager.hasRole(_scopedRole(OFFCHAIN_REPORTER), msg.sender), ErrorsLib.Unauthorized()
        );
        _;
    }

    constructor(
        address _vault,
        address _asset,
        address _roleManager,
        address _custodian,
        uint256 _stalePeriod,
        uint256 _minReportInterval,
        uint256 _maxChangeBps
    ) AccessManaged(_roleManager, _vault) {
        require(_asset != address(0), ErrorsLib.ZeroAddress());

        vault = _vault;
        asset = _asset;
        custodian = _custodian;
        maxChangeBps = _maxChangeBps;
        _setStalePeriod(_stalePeriod);
        _setMinReportInterval(_minReportInterval);
    }

    /* ADMIN — gated by GOVERNANCE_ROLE */

    function setCustodian(address newCustodian) external onlyRole(GOVERNANCE_ROLE) {
        custodian = newCustodian;
        emit EventsLib.SetCustodian(newCustodian);
    }

    function setMaxChangeBps(uint256 newMaxChangeBps) external onlyRole(GOVERNANCE_ROLE) {
        require(newMaxChangeBps <= 10_000, ErrorsLib.RelativeCapAboveOne());
        maxChangeBps = newMaxChangeBps;
        emit EventsLib.SetMaxChangeBps(newMaxChangeBps);
    }

    function setStalePeriod(uint256 newStalePeriod) external onlyRole(GOVERNANCE_ROLE) {
        _setStalePeriod(newStalePeriod);
    }

    function setMinReportInterval(uint256 newMinReportInterval) external onlyRole(GOVERNANCE_ROLE) {
        _setMinReportInterval(newMinReportInterval);
    }

    /* VAULT STRATEGY INTERFACE */

    /// @notice Total assets counted by the Vault.
    /// @dev If the offchain report is stale, only onchain idle assets are counted.
    function realAssets() external view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (isStale()) return idle;

        return idle + uint256(_position.reportedAssets) + uint256(_position.pendingReceivable);
    }

    function totalAssets() external view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (isStale()) return idle;

        return idle + uint256(_position.reportedAssets) + uint256(_position.pendingReceivable);
    }

    /// @notice Liquidity that can be used or requested for withdrawals.
    /// @dev Onchain idle is immediately available. Reported liquidity is offchain-available, not already onchain.
    function availableLiquidity() external view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (isStale()) return idle;

        return idle + uint256(_position.reportedAvailableLiquidity);
    }

    /// @dev Allocation means the Vault already transferred `assets` to this strategy.
    function allocate(bytes memory, uint256 assets, bytes4, address)
        external
        override
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        _recordAllocation(assets);

        ids = new bytes32[](1);
        ids[0] = strategyId();
        change = int256(assets);
    }

    /// @dev Deallocation can only return assets already held by this strategy onchain.
    ///      Offchain assets must be returned to the strategy first.
    function deallocate(bytes memory, uint256 assets, bytes4, address)
        external
        override
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        require(IERC20(asset).balanceOf(address(this)) >= assets, ErrorsLib.InsufficientLiquidity());

        _recordDeallocation(assets);

        ids = new bytes32[](1);
        ids[0] = strategyId();
        change = -int256(assets);

        _approveVault(assets);
    }

    function strategyId() public view returns (bytes32) {
        return keccak256(abi.encode(address(this), asset));
    }

    /* OFFCHAIN CAPITAL FLOW */

    /// @notice Sends onchain idle assets from this strategy to the configured custodian.
    /// @dev This records the transfer as offchain book value at cost until the next NAV report.
    function deployToCustodian(uint256 assets) external onlyManager {
        _deployToCustodian(custodian, assets);
    }

    /// @notice Sends onchain idle assets from this strategy to a specific destination.
    /// @dev Use this only if the destination is part of the approved custody process.
    function deployToCustodian(address destination, uint256 assets) external onlyManager {
        _deployToCustodian(destination, assets);
    }

    function _deployToCustodian(address destination, uint256 assets) internal {
        require(destination != address(0), ErrorsLib.ZeroAddress());
        require(IERC20(asset).balanceOf(address(this)) >= assets, ErrorsLib.InsufficientLiquidity());

        SafeERC20Lib.safeTransfer(asset, destination, assets);
        _recordCapitalDeployed(assets, destination);
    }

    /// @notice Moves reported offchain liquidity into pending receivable.
    /// @dev Call this when a return has been requested from the custodian but has not arrived onchain yet.
    function requestReturn(uint256 assets) external onlyManager {
        _recordReturnRequested(assets);
    }

    /// @notice Records assets that have already arrived back onchain.
    /// @dev The custodian must transfer tokens to this strategy before this call.
    function recordReturn(uint256 assets) external onlyManager {
        require(IERC20(asset).balanceOf(address(this)) >= assets, ErrorsLib.ReturnNotReceived());
        _recordCapitalReturned(assets);
    }

    /* NAV REPORTING */

    /// @notice Reports offchain NAV.
    /// @param newReportedAssets Offchain NAV excluding ERC20 assets currently held by this strategy.
    /// @param newReportedAvailableLiquidity Offchain liquidity excluding ERC20 assets currently held by this strategy.
    /// @param newPendingReceivable Requested but not-yet-received return amount.
    function report(
        uint256 newReportedAssets,
        uint256 newReportedAvailableLiquidity,
        uint256 newPendingReceivable,
        bytes32 newReportHash,
        string calldata newReportURI
    ) external onlyReporter {
        _recordNAVReport(
            newReportedAssets,
            newReportedAvailableLiquidity,
            newPendingReceivable,
            newReportHash,
            newReportURI,
            maxChangeBps
        );
    }

    /// @notice Backward-compatible report function.
    function report(uint256 newReportedAssets, bytes32 newReportHash, string calldata newReportURI)
        external
        onlyReporter
    {
        _recordNAVReport(newReportedAssets, 0, 0, newReportHash, newReportURI, maxChangeBps);
    }

    /// @notice Backward-compatible report function with available liquidity.
    function report(
        uint256 newReportedAssets,
        uint256 newReportedAvailableLiquidity,
        bytes32 newReportHash,
        string calldata newReportURI
    ) external override onlyReporter {
        _recordNAVReport(
            newReportedAssets,
            newReportedAvailableLiquidity,
            0,
            newReportHash,
            newReportURI,
            maxChangeBps
        );
    }

    function _approveVault(uint256 assets) internal {
        (bool success, bytes memory result) =
            asset.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), vault, assets));
        require(success && (result.length == 0 || abi.decode(result, (bool))), ErrorsLib.ApproveReturnedFalse());
    }
}
