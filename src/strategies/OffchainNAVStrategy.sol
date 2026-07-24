// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IVault} from "../interfaces/IVault.sol";
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

    error CannotSkimUnderlying();
    error SkimRecipientUnset();
    event Skim(address indexed token, uint256 amount);
    event SetSkimRecipient(address indexed recipient);

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
        uint256 _maxChangeBps
    ) AccessManaged(_roleManager, _vault) {
        require(_asset != address(0), ErrorsLib.ZeroAddress());

        vault = _vault;
        asset = _asset;
        custodian = _custodian;
        maxChangeBps = _maxChangeBps;
        _setStalePeriod(_stalePeriod);
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

    function setSkimRecipient(address newSkimRecipient) external onlyRole(GOVERNANCE_ROLE) {
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
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
    /// @dev Capital sent to the custodian is booked at cost until the first authoritative report. After
    /// that, the last reported NAV remains in `totalAssets()` even when stale; deposits/mints are blocked
    /// at the vault level while stale so an expired mark cannot be used for new entry pricing.
    function totalAssets() external view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        return idle + uint256(_position.reportedAssets);
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

    /// @notice Atomically returns underlying from the custodian and reconciles the offchain book.
    /// @dev The custodian must approve this strategy before calling. Transfer and accounting either
    /// both succeed or both revert, so returned assets are never double-counted as idle and reported NAV.
    function returnCapital(uint256 assets) external {
        require(msg.sender == custodian, ErrorsLib.Unauthorized());
        require(assets > 0, ErrorsLib.InvalidRequest());
        require(assets <= _position.reportedAssets, ErrorsLib.RequestExceedsReportedAssets());
        require(assets <= _position.reportedAvailableLiquidity, ErrorsLib.RequestExceedsAvailableLiquidity());
        SafeERC20Lib.safeTransferFrom(asset, msg.sender, address(this), assets);
        _recordCapitalReturned(assets);
    }

    /* NAV REPORTING */

    /// @notice Reports offchain NAV and liquidity.
    /// @param newReportedAssets Offchain NAV excluding onchain idle assets.
    /// @param newReportedAvailableLiquidity Offchain liquidity excluding onchain idle assets.
    function report(
        uint256 newReportedAssets,
        uint256 newReportedAvailableLiquidity,
        bytes32 newReportHash,
        string calldata newReportURI
    ) external override onlyReporter {
        // Settle all pre-report accounting under the old mark first. The post-report callback then
        // applies only this strategy's authenticated NAV delta without letting unrelated donations or
        // onchain gains bypass the vault's maxRate.
        IVault(vault).accrueInterest();
        uint256 previousStrategyAssets = IERC20(asset).balanceOf(address(this)) + uint256(_position.reportedAssets);

        _recordNAVReport(newReportedAssets, newReportedAvailableLiquidity, newReportHash, newReportURI, maxChangeBps);

        IVault(vault).syncOffchainNAV(previousStrategyAssets);
    }

    function _approveVault(uint256 assets) internal {
        (bool success, bytes memory result) =
            asset.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), vault, assets));
        require(success && (result.length == 0 || abi.decode(result, (bool))), ErrorsLib.ApproveReturnedFalse());
    }
}
