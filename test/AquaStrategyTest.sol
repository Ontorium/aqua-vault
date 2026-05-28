// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {AquaStrategy} from "../src/strategies/AquaStrategy.sol";
import {AaveLendingPoolMock, ATokenMock} from "./mocks/AaveV2Mock.sol";

/// @notice AquaStrategy is the Aave V2 wrapper: allocate() supplies underlying to the lending pool
/// and receives rebasing aTokens; totalAssets() reads the aToken balance. These tests verify the
/// aToken receipt, interest growth, withdrawal, liquidity capping, and access control — both
/// standalone (pranking as the vault) and end-to-end through the real Vault.
contract AquaStrategyTest is BaseTest {
    AquaStrategy internal strategy;
    AaveLendingPoolMock internal pool;
    ATokenMock internal aToken;

    function setUp() public override {
        super.setUp();

        pool = new AaveLendingPoolMock(address(underlyingToken));
        aToken = new ATokenMock(address(pool), address(underlyingToken));
        pool.setAToken(address(aToken));

        // Strategy's vault is the real BaseTest vault, so we can drive both unit (prank) and
        // integration (vault.allocate) paths against one instance.
        strategy =
            new AquaStrategy(address(vault), address(underlyingToken), address(pool), address(aToken));
    }

    function _expectedId() internal view returns (bytes32) {
        return keccak256(abi.encode(address(strategy), address(aToken)));
    }

    /// @dev Funds the strategy directly (mimicking the Vault transferring assets before allocate).
    function _fundAndAllocateAs(uint256 amount) internal returns (bytes32[] memory ids, int256 change) {
        underlyingToken.mint(address(strategy), amount);
        vm.prank(address(vault));
        (ids, change) = strategy.allocate(hex"", amount, bytes4(0), address(0));
    }

    /* ── CONSTRUCTOR ──────────────────────────────────────────────────────────── */

    function testConstructorWiresAndApproves() public view {
        assertEq(strategy.vault(), address(vault));
        assertEq(strategy.asset(), address(underlyingToken));
        assertEq(strategy.lendingPool(), address(pool));
        assertEq(strategy.aToken(), address(aToken));
        // Constructor pre-approved the pool to pull the asset.
        assertEq(underlyingToken.allowance(address(strategy), address(pool)), type(uint256).max);
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new AquaStrategy(address(0), address(underlyingToken), address(pool), address(aToken));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new AquaStrategy(address(vault), address(0), address(pool), address(aToken));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new AquaStrategy(address(vault), address(underlyingToken), address(0), address(aToken));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new AquaStrategy(address(vault), address(underlyingToken), address(pool), address(0));
    }

    /* ── ALLOCATE → aToken RECEIPT ────────────────────────────────────────────── */

    function testAllocateReceivesATokens(uint256 amount) public {
        amount = bound(amount, 1, 1e30);

        (bytes32[] memory ids, int256 change) = _fundAndAllocateAs(amount);

        // The strategy now holds aTokens equal to the supplied principal.
        assertEq(aToken.balanceOf(address(strategy)), amount, "aToken minted to strategy");
        // Underlying moved out of the strategy into the aToken market.
        assertEq(underlyingToken.balanceOf(address(strategy)), 0, "strategy underlying drained");
        assertEq(underlyingToken.balanceOf(address(aToken)), amount, "market holds underlying");
        // totalAssets mirrors the aToken balance.
        assertEq(strategy.totalAssets(), amount, "totalAssets == aToken balance");

        // Return values: single id keyed by (strategy, aToken), change = +amount.
        assertEq(ids.length, 1);
        assertEq(ids[0], _expectedId(), "id");
        assertEq(change, int256(amount), "change");
    }

    function testAllocateZeroIsNoopButReturnsId() public {
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = strategy.allocate(hex"", 0, bytes4(0), address(0));

        assertEq(aToken.balanceOf(address(strategy)), 0, "no aTokens");
        assertEq(ids[0], _expectedId());
        assertEq(change, 0);
    }

    function testAllocateOnlyVault(address rdm) public {
        vm.assume(rdm != address(vault));
        underlyingToken.mint(address(strategy), 100);
        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        strategy.allocate(hex"", 100, bytes4(0), address(0));
    }

    /* ── INTEREST (rebasing aToken) ───────────────────────────────────────────── */

    function testTotalAssetsGrowsWithATokenInterest(uint256 principal, uint256 interest) public {
        principal = bound(principal, 1e6, 1e30);
        interest = bound(interest, 0, 1e30);

        _fundAndAllocateAs(principal);
        assertEq(strategy.totalAssets(), principal);

        // Simulate Aave interest: the strategy's aToken balance rebases upward.
        aToken.accrue(address(strategy), interest);

        assertEq(strategy.totalAssets(), principal + interest, "interest reflected");
        assertEq(strategy.realAssets(), principal + interest, "realAssets tracks aToken");
    }

    /* ── DEALLOCATE → underlying returned ─────────────────────────────────────── */

    function testDeallocateBurnsATokensAndReturnsUnderlying(uint256 amount, uint256 withdrawAmt) public {
        amount = bound(amount, 1, 1e30);
        withdrawAmt = bound(withdrawAmt, 0, amount);

        _fundAndAllocateAs(amount);

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = strategy.deallocate(hex"", withdrawAmt, bytes4(0), address(0));

        assertEq(aToken.balanceOf(address(strategy)), amount - withdrawAmt, "aToken burned");
        // Underlying flows back to the strategy (vault then pulls it via safeTransferFrom).
        assertEq(underlyingToken.balanceOf(address(strategy)), withdrawAmt, "underlying returned");
        assertEq(ids[0], _expectedId());
        assertEq(change, -int256(withdrawAmt), "change negative");
    }

    function testDeallocateRevertsOnShortfall() public {
        uint256 amount = 1_000e18;
        _fundAndAllocateAs(amount);

        // Pool will under-deliver by 1 wei on the next withdraw.
        pool.setWithdrawShortfall(1);

        vm.prank(address(vault));
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        strategy.deallocate(hex"", 500e18, bytes4(0), address(0));
    }

    function testDeallocateOnlyVault(address rdm) public {
        vm.assume(rdm != address(vault));
        _fundAndAllocateAs(100);
        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        strategy.deallocate(hex"", 100, bytes4(0), address(0));
    }

    /* ── availableLiquidity capping ───────────────────────────────────────────── */

    function testAvailableLiquidityFullWhenMarketLiquid(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        _fundAndAllocateAs(amount);
        // Market holds all underlying → liquidity == totalAssets.
        assertEq(strategy.availableLiquidity(), amount);
    }

    function testAvailableLiquidityCapsAtMarketLiquidity() public {
        uint256 amount = 1_000e18;
        _fundAndAllocateAs(amount);

        // Simulate utilization: 700 of the market's underlying is "borrowed out".
        underlyingToken.burn(address(aToken), 700e18);

        // totalAssets still 1000 (aToken balance unchanged), but only 300 underlying remains.
        assertEq(strategy.totalAssets(), 1_000e18);
        assertEq(strategy.availableLiquidity(), 300e18, "capped at market liquidity");
    }

    /* ── INTEGRATION via real Vault ───────────────────────────────────────────── */

    /// forge-config: default.isolate = true
    function testVaultAllocateRoutesToAaveAndReceivesATokens() public {
        // Register the strategy and lift the cap for its specific id.
        bytes memory idData = abi.encode(address(strategy), address(aToken));
        vm.startPrank(governance);
        strategyManager.addStrategy(address(strategy), 1 /* ONCHAIN */, 0, 0);
        strategyManager.increaseAbsoluteCap(idData, type(uint128).max);
        strategyManager.increaseRelativeCap(idData, WAD);
        vm.stopPrank();

        // A user deposits, then the allocator routes the principal into Aave.
        uint256 deposit = 1_000e18;
        address user = makeAddr("user");
        underlyingToken.mint(user, deposit);
        vm.startPrank(user);
        underlyingToken.approve(address(vault), deposit);
        vault.deposit(deposit, user);
        vm.stopPrank();

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        // aTokens received by the strategy; StrategyManager sees the assets.
        assertEq(aToken.balanceOf(address(strategy)), deposit, "strategy holds aTokens");
        assertEq(strategyManager.totalStrategyAssets(), deposit, "SM aggregates aToken value");
        assertEq(strategyManager.allocation(_expectedId()), deposit, "cap allocation tracked");

        // Interest accrues in Aave; the vault's totalAssets picks it up (within maxRate).
        vm.prank(governance);
        vault.setMaxRate(MAX_MAX_RATE);
        aToken.accrue(address(strategy), 100e18);
        skip(365 days);
        assertApproxEqAbs(vault.totalAssets(), deposit + 100e18, 1, "vault sees Aave interest");
    }
}
