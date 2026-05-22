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
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed sender,
        address indexed receiver,
        address onBehalf,
        uint256 assets,
        uint256 shares
    );
    event WithdrawalClaimed(uint256 indexed requestId, address indexed receiver, uint256 assets);

    // Vault creation events
    event Constructor(address indexed owner, address indexed asset);

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
    event SetOwner(address indexed newOwner);
    event SetCurator(address indexed newCurator);
    event SetIsSentinel(address indexed account, bool newIsSentinel);
    event SetName(string newName);
    event SetSymbol(string newSymbol);
    event SetIsAllocator(address indexed account, bool newIsAllocator);
    event SetReceiveSharesGate(address indexed newReceiveSharesGate);
    event SetSendSharesGate(address indexed newSendSharesGate);
    event SetReceiveAssetsGate(address indexed newReceiveAssetsGate);
    event SetSendAssetsGate(address indexed newSendAssetsGate);
    event SetStrategyRegistry(address indexed newStrategyRegistry);
    event AddStrategy(address indexed account);
    event RemoveStrategy(address indexed account);
    event SetGovernanceTarget(address indexed target, bool allowed);
    event SetGovernanceTimelock(address indexed target, bytes4 indexed selector, uint256 newDuration);
    event SetGovernanceAbdicated(address indexed target, bytes4 indexed selector, bool newAbdicated);

    event SetPerformanceFee(uint256 newPerformanceFee);
    event SetPerformanceFeeRecipient(address indexed newPerformanceFeeRecipient);
    event SetManagementFee(uint256 newManagementFee);
    event SetManagementFeeRecipient(address indexed newManagementFeeRecipient);
    event DecreaseAbsoluteCap(address indexed sender, bytes32 indexed id, bytes idData, uint256 newAbsoluteCap);
    event IncreaseAbsoluteCap(bytes32 indexed id, bytes idData, uint256 newAbsoluteCap);
    event DecreaseRelativeCap(address indexed sender, bytes32 indexed id, bytes idData, uint256 newRelativeCap);
    event IncreaseRelativeCap(bytes32 indexed id, bytes idData, uint256 newRelativeCap);
    event SetMaxRate(uint256 newMaxRate);
    event SetForceDeallocatePenalty(address indexed strategy, uint256 forceDeallocatePenalty);

    // StrategyManager-related events
    event SetStrategyManager(address indexed newStrategyManager);
    event SetStrategyActive(address indexed strategy, bool active);
    event SetStrategyCapBps(address indexed strategy, uint256 capBps);
    event SetStrategyTargetBps(address indexed strategy, uint256 targetBps);
    event SetStrategyKind(address indexed strategy, uint8 kind);
    event AfterAllocate(address indexed strategy, bytes32[] ids, int256 change, uint256 strategyAllocation);
    event AfterDeallocate(address indexed strategy, bytes32[] ids, int256 change, uint256 strategyAllocation);
    event Rebalance(address indexed caller, uint256 actionsLength);
}
