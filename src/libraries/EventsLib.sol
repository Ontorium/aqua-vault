// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.28;

library EventsLib {
    // ERC20 events
    event Approval(address indexed owner, address indexed spender, uint256 shares);
    event Transfer(address indexed from, address indexed to, uint256 shares);
    /// @dev Emitted when the allowance is updated by transferFrom (not when it is updated by permit, approve, withdraw,
    /// redeem because their respective events allow to track the allowance).
    event AllowanceUpdatedByTransferFrom(address indexed owner, address indexed spender, uint256 shares);
    event Permit(address indexed owner, address indexed spender, uint256 shares, uint256 nonce, uint256 deadline);

    // ERC4626 events
    event Deposit(address indexed sender, address indexed onBehalf, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed onBehalf, uint256 assets, uint256 shares
    );
    /// @dev Per-user accumulating queue (Centrifuge-style). No `requestId`: identity is the
    /// `onBehalf` address; multiple queued requests for the same user merge into one slot.
    event WithdrawalRequested(address indexed sender, address indexed onBehalf, uint256 assets, uint256 shares);
    /// @dev Operator (ALLOCATOR_ROLE) moved a user's pending request into the reserved/claimable pool.
    event WithdrawalFulfilled(address indexed onBehalf, uint256 assets);
    event WithdrawalClaimed(address indexed onBehalf, uint256 assets);

    // Vault creation events
    event Constructor(address indexed owner, address indexed asset);

    // RoleManager events (membership changes are emitted as RoleGranted/RoleRevoked by AccessControl)
    /// @dev Emitted when a scope's GOVERNANCE→operational admin hierarchy is wired in the RoleManager.
    event RegisterScope(address indexed scope);

    // Pause events
    event Paused(address indexed sender);
    event Unpaused(address indexed sender);

    // Allocation events
    event Allocate(address indexed sender, address indexed strategy, uint256 assets, bytes32[] ids, int256 change);
    event Deallocate(address indexed sender, address indexed strategy, uint256 assets, bytes32[] ids, int256 change);
    event ForceDeallocate(
        address indexed sender,
        address strategy,
        uint256 assets,
        address indexed onBehalf,
        bytes32[] ids,
        uint256 penaltyAssets
    );

    // Fee and interest events
    event AccrueInterest(
        uint256 previousTotalAssets, uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares
    );

    // Governance timelock events
    event GovernanceRevoke(address indexed sender, address indexed target, bytes4 indexed selector, bytes data);
    event GovernanceSubmit(address indexed target, bytes4 indexed selector, bytes data, uint256 executableAt);
    event GovernanceAccept(address indexed target, bytes4 indexed selector, bytes data);

    // Configuration events
    // @dev Owner/curator/sentinel/allocator membership changes are emitted by RoleManager
    // as RoleGranted/RoleRevoked, NOT here.
    event SetName(string newName);
    event SetSymbol(string newSymbol);
    event SetReceiveSharesGate(address indexed newReceiveSharesGate);
    event SetSendSharesGate(address indexed newSendSharesGate);
    event SetReceiveAssetsGate(address indexed newReceiveAssetsGate);
    event SetSendAssetsGate(address indexed newSendAssetsGate);
    event SetPriceManager(address indexed newPriceManager);
    event SetStrategyRegistry(address indexed newStrategyRegistry);
    event AddStrategy(address indexed account);
    event RemoveStrategy(address indexed account);
    event SetGovernanceTarget(address indexed target, bool allowed);
    event SetTimelock(address indexed target, bytes4 indexed selector, uint256 newDuration);
    event SetGovernanceAbdicated(address indexed target, bytes4 indexed selector, bool newAbdicated);

    event SetPerformanceFee(uint256 newPerformanceFee);
    event SetPerformanceFeeRecipient(address indexed newPerformanceFeeRecipient);
    event SetManagementFee(uint256 newManagementFee);
    event SetManagementFeeRecipient(address indexed newManagementFeeRecipient);
    event SetDepositFee(uint256 newDepositFee);
    event SetWithdrawalFee(uint256 newWithdrawalFee);
    event SetProtocolFeeRecipient(address indexed newProtocolFeeRecipient);
    event SetMinReportInterval(uint256 newMinReportInterval);
    event DecreaseAbsoluteCap(address indexed sender, bytes32 indexed id, bytes idData, uint256 newAbsoluteCap);
    event IncreaseAbsoluteCap(bytes32 indexed id, bytes idData, uint256 newAbsoluteCap);
    event DecreaseRelativeCap(address indexed sender, bytes32 indexed id, bytes idData, uint256 newRelativeCap);
    event IncreaseRelativeCap(bytes32 indexed id, bytes idData, uint256 newRelativeCap);
    event SetMaxRate(uint256 newMaxRate);
    event SetForceDeallocatePenalty(address indexed strategy, uint256 forceDeallocatePenalty);
    event SyncReportedNAV(address indexed priceManager, uint256 previousTotalAssets, uint256 newTotalAssets);
    event LiquidityProvided(address indexed lender, uint256 amount);
    event LiquidityRemoved(address indexed lender, uint256 amount);

    // StrategyManager-related events
    event SetStrategyManager(address indexed newStrategyManager);
    event SetStrategyActive(address indexed strategy, bool active);
    event SetStrategyCapBps(address indexed strategy, uint256 capBps);
    event SetStrategyTargetBps(address indexed strategy, uint256 targetBps);
    event SetStrategyKind(address indexed strategy, uint8 kind);
    event AfterAllocate(address indexed strategy, bytes32[] ids, int256 change, uint256 strategyAllocation);
    event AfterDeallocate(address indexed strategy, bytes32[] ids, int256 change, uint256 strategyAllocation);
    event Rebalance(address indexed caller, uint256 actionsLength);

    // OffchainBalanceSheet events (emitted from the strategy contract address)
    event StrategyAllocated(uint256 assets);
    event StrategyDeallocated(uint256 assets);
    event CapitalDeployed(uint256 assets, address indexed destination);
    event ReturnRequested(uint256 assets);
    event CapitalReturned(uint256 assets);
    event NAVReported(
        uint256 reportedAssets,
        uint256 reportedAvailableLiquidity,
        uint256 pendingReceivable,
        bytes32 indexed reportHash,
        string reportURI,
        uint64 timestamp
    );
    event StalePeriodSet(uint256 stalePeriod);

    // OffchainNAVStrategy config events
    // @dev Manager/reporter changes are emitted by RoleManager as RoleGranted/RoleRevoked
    // (using per-strategy scoped role hashes), NOT here.
    event SetCustodian(address indexed custodian);
    event SetMaxChangeBps(uint256 maxChangeBps);

    // PriceManager events
    event PriceManagerUpdate(
        address indexed vault,
        address indexed offchainStrategy,
        uint256 netAssetValue,
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 pricePerShare
    );
}
