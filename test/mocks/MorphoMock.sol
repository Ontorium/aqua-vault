// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {MarketParams, Market, Position, Id} from "../../src/strategies/morpho/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../src/strategies/morpho/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../src/strategies/morpho/libraries/SharesMathLib.sol";
import {SafeERC20Lib} from "../../src/libraries/SafeERC20Lib.sol";

/// @notice Minimal Morpho Blue protocol mock — implements just the surface area MorphoStrategy and
/// `MorphoBalancesLib` / `MorphoLib` touch: `market(id)`, `position(id, user)`, `supply`, `withdraw`,
/// `accrueInterest`. Pricing math uses the real `SharesMathLib` so virtual-share semantics match the
/// production protocol (mintedShares >= assets check etc.).
///
/// @dev Interest is NOT auto-accrued (paired IRM is `IrmMock` returning 0). Tests simulate interest
/// explicitly via {simulateInterest} which inflates `totalSupplyAssets` directly — cleaner than
/// time+rate-based projection.
contract MorphoMock {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    mapping(Id => Market) internal _markets;
    mapping(Id => mapping(address => Position)) internal _positions;

    /* GETTERS (match IMorpho surface) */

    function market(Id id) external view returns (Market memory) {
        return _markets[id];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    /* MUTATING (match IMorpho surface) */

    function accrueInterest(MarketParams memory mp) external {
        Id id = mp.id();
        _markets[id].lastUpdate = uint128(block.timestamp);
    }

    function supply(MarketParams memory mp, uint256 assets, uint256 /* shares */, address onBehalf, bytes calldata)
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied)
    {
        Id id = mp.id();
        Market storage m = _markets[id];

        if (m.lastUpdate == 0) m.lastUpdate = uint128(block.timestamp);

        sharesSupplied = assets.toSharesDown(m.totalSupplyAssets, m.totalSupplyShares);

        m.totalSupplyAssets += uint128(assets);
        m.totalSupplyShares += uint128(sharesSupplied);
        _positions[id][onBehalf].supplyShares += sharesSupplied;

        SafeERC20Lib.safeTransferFrom(mp.loanToken, msg.sender, address(this), assets);

        return (assets, sharesSupplied);
    }

    function withdraw(MarketParams memory mp, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
    {
        Id id = mp.id();
        Market storage m = _markets[id];

        sharesWithdrawn = assets.toSharesUp(m.totalSupplyAssets, m.totalSupplyShares);

        m.totalSupplyAssets -= uint128(assets);
        m.totalSupplyShares -= uint128(sharesWithdrawn);
        _positions[id][onBehalf].supplyShares -= sharesWithdrawn;

        SafeERC20Lib.safeTransfer(mp.loanToken, receiver, assets);

        return (assets, sharesWithdrawn);
    }

    /* TEST HELPERS (NOT in IMorpho — for orchestrating scenarios) */

    /// @dev Simulate interest accrual on a market by inflating `totalSupplyAssets`. Shares unchanged →
    /// share price rises → suppliers receive more on withdraw.
    function simulateInterest(Id id, uint256 extraAssets) external {
        _markets[id].totalSupplyAssets += uint128(extraAssets);
    }

    /// @dev Simulate a borrow (raises totalBorrowAssets), reducing market available liquidity. Useful
    /// for testing `MorphoStrategy.availableLiquidity()` capping.
    function simulateBorrow(Id id, uint256 amount) external {
        _markets[id].totalBorrowAssets += uint128(amount);
    }
}
