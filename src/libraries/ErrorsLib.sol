// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.28;

library ErrorsLib {
    error Abdicated();
    error AbsoluteCapExceeded();
    error AbsoluteCapNotDecreasing();
    error AbsoluteCapNotIncreasing();
    error ApproveReturnedFalse();
    error ApproveReverted();
    error AutomaticallyTimelocked();
    error AvailableExceedsReportedAssets();
    error CannotReceiveShares();
    error CannotReceiveAssets();
    error CannotSendShares();
    error CannotSendAssets();
    error CapExceeded();
    error CastOverflow();
    error DataAlreadyPending();
    error DataNotTimelocked();
    error DeallocationExceedsAllocation();
    error FeeInvariantBroken();
    error FeeTooHigh();
    error InsufficientLiquidity();
    error InvalidStrategyManager();
    error InvalidTarget();
    error InvalidRequest();
    error InvalidSigner();
    error MaxChangeExceeded();
    error MaxRateTooHigh();
    error NoCode();
    error NotStrategy();
    error NotInStrategyRegistry();
    error Paused();
    error PenaltyTooHigh();
    error PermitDeadlineExpired();
    error RelativeCapAboveOne();
    error RelativeCapExceeded();
    error RelativeCapNotDecreasing();
    error RelativeCapNotIncreasing();
    error RequestAlreadyClaimed();
    error RequestExceedsAvailableLiquidity();
    error RequestExceedsReportedAssets();
    error RequestNotPending();
    error ReportTooSoon();
    error ReturnNotReceived();
    error StaleOffchainStrategy();
    error TimelockNotDecreasing();
    error TimelockNotExpired();
    error TimelockNotIncreasing();
    error TransferFromReturnedFalse();
    error TransferFromReverted();
    error TransferReturnedFalse();
    error TransferReverted();
    error Unauthorized();
    error ZeroAbsoluteCap();
    error ZeroAddress();
    error ZeroAllocation();
}
