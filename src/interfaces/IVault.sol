// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity >=0.5.0;

import {IERC4626} from "./IERC4626.sol";
import {IERC2612} from "./IERC2612.sol";

struct Caps {
    uint256 allocation;
    uint128 absoluteCap;
    uint128 relativeCap;
}

/// @dev Single storage slot per `onBehalf` (`uint128 + uint128 = 256 bits` packed). Subsequent queued
/// withdrawals accumulate into the same slot; a second `feeAtRequest` slot is added only when fees are
/// active. Cleared via `delete` on claim/cancel for full refund.
/// @dev `assets` is the gross amount owed (pre-withdrawal-fee); `feeAtRequest` snapshots the
/// `withdrawalFee` (WAD-scaled) at the moment the request entered the queue so fee policy changes
/// between request and claim do NOT affect the queued user. `shares` is the cumulative share count
/// burned, restored on cancel.
struct PendingWithdrawal {
    uint128 assets;
    uint128 shares;
    uint64 feeAtRequest;
}

/// @dev One leg of a {IVault.rebalance} batch. `isAllocate` selects allocate (vault -> strategy) vs
/// deallocate (strategy -> vault); `data` is the strategy-specific payload.
struct RebalanceAction {
    address strategy;
    bool isAllocate;
    uint256 assets;
    bytes data;
}

interface IVault is IERC4626, IERC2612 {
    // State variables
    function virtualShares() external view returns (uint256);
    // @dev All role-based permissions live in the central RoleManager (queryable directly on Vault via
    // `Vault(address).roleManager()` which returns the IAccessControl handle).
    function receiveSharesGate() external view returns (address);
    function sendSharesGate() external view returns (address);
    function receiveAssetsGate() external view returns (address);
    function sendAssetsGate() external view returns (address);
    function strategyManager() external view returns (address);
    function firstTotalAssets() external view returns (uint256);
    function _totalAssets() external view returns (uint128);
    function lastUpdate() external view returns (uint64);
    function maxRate() external view returns (uint64);
    function performanceFee() external view returns (uint96);
    function performanceFeeRecipient() external view returns (address);
    function managementFee() external view returns (uint96);
    function managementFeeRecipient() external view returns (address);
    function depositFee() external view returns (uint96);
    function withdrawalFee() external view returns (uint96);
    function protocolFeeRecipient() external view returns (address);
    function pendingWithdrawal(address onBehalf)
        external
        view
        returns (uint128 assets, uint128 shares, uint64 feeAtRequest);
    function claimableAssets(address onBehalf) external view returns (uint128);
    function claimableFee(address onBehalf) external view returns (uint64);
    function reservedAssets() external view returns (uint256);
    function pendingClaimableAssets() external view returns (uint256);
    function paused() external view returns (bool);

    // @dev Strategy registry, caps, allocation, per-strategy/per-id queries and aggregate liquidity views
    // are NOT exposed here. Read them directly from StrategyManager (obtainable via strategyManager()).

    // Gating
    function canSendShares(address account) external view returns (bool);
    function canReceiveShares(address account) external view returns (bool);
    function canSendAssets(address account) external view returns (bool);
    function canReceiveAssets(address account) external view returns (bool);

    // Multicall
    function multicall(bytes[] calldata data) external;

    // Governance-owned Vault admin (all gated by RoleManager.GOVERNANCE_ROLE)
    function setName(string calldata newName) external;
    function setSymbol(string calldata newSymbol) external;
    function setReceiveSharesGate(address newReceiveSharesGate) external;
    function setSendSharesGate(address newSendSharesGate) external;
    function setReceiveAssetsGate(address newReceiveAssetsGate) external;
    function setSendAssetsGate(address newSendAssetsGate) external;
    function setStrategyManager(address newStrategyManager) external;
    function setPerformanceFee(uint256 newPerformanceFee) external;
    function setManagementFee(uint256 newManagementFee) external;
    function setPerformanceFeeRecipient(address newPerformanceFeeRecipient) external;
    function setManagementFeeRecipient(address newManagementFeeRecipient) external;
    function setDepositFee(uint256 newDepositFee) external;
    function setWithdrawalFee(uint256 newWithdrawalFee) external;
    function setProtocolFeeRecipient(address newProtocolFeeRecipient) external;
    function setMaxRate(uint256 newMaxRate) external;

    // Pause controls (SENTINEL pauses, GOVERNANCE unpauses)
    function pause() external;
    function unpause() external;

    // Allocator functions
    function allocate(address strategy, bytes calldata data, uint256 assets) external;
    function deallocate(address strategy, bytes calldata data, uint256 assets) external;
    /// @notice Batched allocate/deallocate to move capital between strategies in one call. Allocate legs
    /// respect the pause; deallocate (exit) legs remain available while paused.
    function rebalance(RebalanceAction[] calldata actions) external;
    /// @notice Operator (ALLOCATOR_ROLE) moves each user's full pending request into their reserved
    /// `claimableAssets`, locking liquidity per-user. Caller controls fulfillment order via the list.
    function fulfillWithdrawal(address[] calldata onBehalfs) external;

    // Exchange rate
    function accrueInterest() external;
    function forceSyncReportedNAV() external;
    function accrueInterestView()
        external
        view
        returns (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares);

    // Withdrawal queue (per-user, operator-fulfilled, ERC-7540 / Centrifuge style)
    /// @notice Settles `onBehalf`'s fulfilled (reserved) withdrawal. Permissionless; assets always flow to
    /// `onBehalf` (not to msg.sender). Only claimable after the operator calls {fulfillWithdrawal}.
    function claim(address onBehalf) external returns (uint256 assets);
    function isClaimable(address onBehalf) external view returns (bool);
    function availableLiquidity() external view returns (uint256);

    // Force deallocate
    function forceDeallocate(address strategy, bytes calldata data, uint256 assets, address onBehalf)
        external
        returns (uint256 penaltyShares);
}
