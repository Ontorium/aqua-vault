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
    /// @dev Per-receiver accumulating queue. Shares are escrowed, not burned, until fulfillment.
    /// `assets` is the request-time estimate only; settlement uses the fulfillment-time NAV.
    event WithdrawalRequested(
        address indexed sender,
        address indexed onBehalf,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );
    /// @dev Operator priced and burned escrowed shares, then reserved the resulting claimable assets.
    event WithdrawalFulfilled(address indexed receiver, uint256 assets, uint256 shares);
    event WithdrawalClaimed(address indexed receiver, uint256 assets);

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
    event DecreaseAbsoluteCap(address indexed sender, bytes32 indexed id, bytes idData, uint256 newAbsoluteCap);
    event IncreaseAbsoluteCap(bytes32 indexed id, bytes idData, uint256 newAbsoluteCap);
    event DecreaseRelativeCap(address indexed sender, bytes32 indexed id, bytes idData, uint256 newRelativeCap);
    event IncreaseRelativeCap(bytes32 indexed id, bytes idData, uint256 newRelativeCap);
    event SetMaxRate(uint256 newMaxRate);
    event SetForceDeallocatePenalty(address indexed strategy, uint256 forceDeallocatePenalty);
    event ForceSyncReportedNAV(address indexed caller, uint256 previousTotalAssets, uint256 newTotalAssets);

    // StrategyManager-related events
    event SetStrategyManager(address indexed newStrategyManager);
    event SetStrategyActive(address indexed strategy, bool active);
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
}
