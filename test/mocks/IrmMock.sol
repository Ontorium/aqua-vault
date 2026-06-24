// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IIrm} from "../../src/strategies/morpho/interfaces/IIrm.sol";
import {MarketParams, Market} from "../../src/strategies/morpho/interfaces/IMorpho.sol";

/// @notice Minimal IRM mock that always returns a zero borrow rate. With zero rate the periphery
/// `MorphoBalancesLib.expectedMarketBalances` projection is a no-op, so tests can deterministically
/// simulate interest accrual through `MorphoMock.simulateInterest` rather than through time + rate.
contract IrmMock is IIrm {
    function borrowRate(MarketParams memory, Market memory) external pure returns (uint256) {
        return 0;
    }

    function borrowRateView(MarketParams memory, Market memory) external pure returns (uint256) {
        return 0;
    }
}
