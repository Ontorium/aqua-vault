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

/// @notice Offchain strategy with internal balance-sheet accounting.
/// @dev Reporter and manager permissions are delegated to the shared RoleManager.
contract OffchainNAVStrategy is IOffchainNAVStrategy, OffchainBalanceSheet, AccessManaged {
    /// @dev Per-instance role names.
    bytes32 internal constant OFFCHAIN_REPORTER = keccak256("OFFCHAIN_REPORTER");
    bytes32 internal constant OFFCHAIN_MANAGER = keccak256("OFFCHAIN_MANAGER");

    address public immutable override vault;
    address public immutable override asset;

    address public custodian;
    uint256 public maxChangeBps;
    /// @dev Recipient for non-underlying token sweeps.
    address public skimRecipient;

    /// @dev If true, return flows are tracked onchain via `requestReturn` and `recordReturn`.
    bool public strictMode;

    error CannotSkimUnderlying();
    error SkimRecipientUnset();
    error StrictModeRequired();
    error PendingReceivableNonZero();

    event Skim(address indexed token, uint256 amount);
    event SetSkimRecipient(address indexed recipient);
    event SetStrictMode(bool strict);

    modifier onlyVault() {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        _;
    }

    modifier onlyManager() {
        require(roleManager.hasRole(_scopedRole(OFFCHAIN_MANAGER), msg.sender), ErrorsLib.Unauthorized());
        _;
    }

    modifier onlyReporter() {
        require(roleManager.hasRole(_scopedRole(OFFCHAIN_REPORTER), msg.sender), ErrorsLib.Unauthorized());
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

    function setSkimRecipient(address newSkimRecipient) external onlyRole(GOVERNANCE_ROLE) {
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @notice Sets the return-flow accounting mode.
    /// @dev Strict mode cannot be disabled while `pendingReceivable` is non-zero.
    function setStrictMode(bool _strict) external onlyRole(GOVERNANCE_ROLE) {
        if (!_strict && _position.pendingReceivable != 0) revert PendingReceivableNonZero();
        strictMode = _strict;
        emit SetStrictMode(_strict);
    }

    /* SKIM */

    /// @notice Sweeps a non-underlying token balance to `skimRecipient`.
    function skim(address token) external {
        address recipient = skimRecipient;
        require(recipient != address(0), SkimRecipientUnset());
        require(msg.sender == recipient, ErrorsLib.Unauthorized());
        require(token != asset, CannotSkimUnderlying());

        uint256 balance = IERC20(token).balanceOf(address(this));
        SafeERC20Lib.safeTransfer(token, recipient, balance);
        emit Skim(token, balance);
    }

    /* VAULT STRATEGY INTERFACE */

    /// @notice Returns the assets counted by the vault.
    /// @dev Before the first report only onchain idle counts. Once at least one report exists, the last
    /// reported NAV remains in `totalAssets()` even when it becomes stale; deposits/mints are blocked at
    /// the vault level while stale so an expired mark cannot be used for new entry pricing.
    function totalAssets() external view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (_position.lastReportTime == 0) return idle;

        return idle + uint256(_position.reportedAssets) + uint256(_position.pendingReceivable);
    }

    /// @notice Returns available liquidity for withdrawals.
    function availableLiquidity() external view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (_position.lastReportTime == 0 || isStale()) return idle;

        return idle + uint256(_position.reportedAvailableLiquidity);
    }

    /// @dev The vault transfers assets before calling this hook.
    function allocate(bytes calldata, uint256 assets, bytes4, address)
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

    /// @dev Only onchain assets can be returned here.
    function deallocate(bytes calldata, uint256 assets, bytes4, address)
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

    /// @notice Sends idle assets to the configured custodian.
    function deployToCustodian(uint256 assets) external onlyManager {
        _deployToCustodian(custodian, assets);
    }

    /// @notice Sends idle assets to a specific destination.
    function deployToCustodian(address destination, uint256 assets) external onlyManager {
        _deployToCustodian(destination, assets);
    }

    function _deployToCustodian(address destination, uint256 assets) internal {
        require(destination != address(0), ErrorsLib.ZeroAddress());
        require(IERC20(asset).balanceOf(address(this)) >= assets, ErrorsLib.InsufficientLiquidity());

        SafeERC20Lib.safeTransfer(asset, destination, assets);
        _recordCapitalDeployed(assets, destination);
    }

    /// @notice Marks assets as in transit from the custodian.
    /// @dev Available only in strict mode.
    function requestReturn(uint256 assets) external onlyManager {
        if (!strictMode) revert StrictModeRequired();
        _recordReturnRequested(assets);
    }

    /// @notice Records assets returned by the custodian.
    /// @dev Available only in strict mode.
    function recordReturn(uint256 assets) external onlyManager {
        if (!strictMode) revert StrictModeRequired();
        require(IERC20(asset).balanceOf(address(this)) >= assets, ErrorsLib.ReturnNotReceived());
        _recordCapitalReturned(assets);
    }

    /* NAV REPORTING */

    /// @notice Reports offchain NAV and liquidity.
    /// @param newReportedAssets Offchain NAV excluding onchain idle assets.
    /// @param newReportedAvailableLiquidity Offchain liquidity excluding onchain idle assets.
    /// @param newPendingReceivable Return amount requested but not yet received.
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

    /// @notice Backward-compatible report function with liquidity.
    function report(
        uint256 newReportedAssets,
        uint256 newReportedAvailableLiquidity,
        bytes32 newReportHash,
        string calldata newReportURI
    ) external override onlyReporter {
        _recordNAVReport(newReportedAssets, newReportedAvailableLiquidity, 0, newReportHash, newReportURI, maxChangeBps);
    }

    function _approveVault(uint256 assets) internal {
        (bool success, bytes memory result) =
            asset.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), vault, assets));
        require(success && (result.length == 0 || abi.decode(result, (bool))), ErrorsLib.ApproveReturnedFalse());
    }
}
