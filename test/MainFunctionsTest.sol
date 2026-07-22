// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract MainFunctionsTest is BaseTest {
    using MathLib for uint256;

    uint256 internal constant MAX_TEST_ASSETS = 1e36;
    uint256 internal constant MAX_TEST_SHARES = 1e36;
    uint256 internal constant INITIAL_DEPOSIT = 1e18 - 123456789;

    uint256 internal initialSharesDeposit;
    uint256 internal totalAssetsAfterInterest;

    function setUp() public override {
        super.setUp();

        vm.prank(governance);
        vault.setMaxRate(MAX_MAX_RATE);

        underlyingToken.mint(address(this), INITIAL_DEPOSIT);
        underlyingToken.approve(address(vault), type(uint256).max);

        initialSharesDeposit = vault.deposit(INITIAL_DEPOSIT, address(this));

        assertEq(underlyingToken.balanceOf(address(vault)), INITIAL_DEPOSIT, "balanceOf(vault)");
        assertEq(underlyingToken.totalSupply(), INITIAL_DEPOSIT, "totalSupply token");
        assertEq(vault.balanceOf(address(this)), initialSharesDeposit, "balanceOf(this)");
        assertEq(vault.totalSupply(), initialSharesDeposit, "totalSupply vault");

        // Inject a rounding error so the share price is non-trivial.
        skip(1); // needed since maxRate clamps growth per-second
        underlyingToken.mint(address(this), 123456789);
        underlyingToken.transfer(address(vault), 123456789);
        assertNotEq((vault.totalAssets() + 1) % (vault.totalSupply() + vault.virtualShares()), 0);

        assertEq(underlyingToken.balanceOf(address(vault)), 1e18, "balanceOf(vault)");
        totalAssetsAfterInterest = vault.totalAssets();
    }

    function testConstructorWires() public view {
        assertEq(vault.asset(), address(underlyingToken));
        // The strategyManager was wired via setStrategyManager during factory deployment.
        assertEq(vault.strategyManager(), address(strategyManager));
        // lastUpdate is the *prior* accrual timestamp; setUp advanced the clock with skip(1) after the
        // last accrueInterest, so this must be in the past (but non-zero).
        assertGt(vault.lastUpdate(), 0);
        assertLe(vault.lastUpdate(), block.timestamp);
    }

    function testMint(uint256 shares, address receiver) public {
        vm.assume(receiver != address(0));
        shares = bound(shares, 0, MAX_TEST_SHARES);

        uint256 expectedAssets = shares.mulDivUp(vault.totalAssets() + 1, vault.totalSupply() + vault.virtualShares());
        uint256 previewedAssets = vault.previewMint(shares);
        assertEq(previewedAssets, expectedAssets, "previewedAssets != expected");

        underlyingToken.mint(address(this), expectedAssets);
        vm.expectEmit();
        emit EventsLib.Deposit(address(this), receiver, expectedAssets, shares);
        uint256 assets = vault.mint(shares, receiver);

        assertEq(assets, expectedAssets, "assets != expected");
        assertEq(underlyingToken.balanceOf(address(vault)), totalAssetsAfterInterest + assets, "balanceOf(vault)");

        uint256 expectedShares = receiver == address(this) ? initialSharesDeposit + shares : shares;
        assertEq(vault.balanceOf(receiver), expectedShares, "balanceOf(receiver)");
        assertEq(vault.totalSupply(), initialSharesDeposit + shares, "vault totalSupply");
    }

    function testDeposit(uint256 assets, address receiver) public {
        vm.assume(receiver != address(0));
        assets = bound(assets, 0, MAX_TEST_ASSETS);

        uint256 expectedShares = assets.mulDivDown(vault.totalSupply() + vault.virtualShares(), vault.totalAssets() + 1);
        uint256 previewedShares = vault.previewDeposit(assets);
        assertEq(previewedShares, expectedShares, "previewedShares != expected");

        underlyingToken.mint(address(this), assets);
        vm.expectEmit();
        emit EventsLib.Deposit(address(this), receiver, assets, expectedShares);
        uint256 shares = vault.deposit(assets, receiver);

        assertEq(shares, expectedShares, "shares != expected");
        assertEq(underlyingToken.balanceOf(address(vault)), totalAssetsAfterInterest + assets, "balanceOf(vault)");

        uint256 expectedTotalShares = receiver == address(this) ? initialSharesDeposit + shares : shares;
        assertEq(vault.balanceOf(receiver), expectedTotalShares, "balanceOf(receiver)");
        assertEq(vault.totalSupply(), initialSharesDeposit + shares, "vault totalSupply");
    }

    function testRedeem(uint256 shares, uint256 sharesApproved, address receiver, address spender, bool approveMax)
        public
    {
        vm.assume(receiver != address(0));
        vm.assume(receiver != spender);
        vm.assume(receiver != address(vault));
        shares = bound(shares, 0, initialSharesDeposit);
        sharesApproved = bound(sharesApproved, shares, shares * 2);

        uint256 expectedAssets = shares.mulDivDown(vault.totalAssets() + 1, vault.totalSupply() + vault.virtualShares());
        uint256 previewedAssets = vault.previewRedeem(shares);
        assertEq(previewedAssets, expectedAssets, "previewedAssets != expected");

        vault.approve(spender, approveMax ? type(uint256).max : sharesApproved);

        vm.expectEmit();
        emit EventsLib.Withdraw(spender, receiver, address(this), expectedAssets, shares);
        vm.prank(spender);
        uint256 assets = vault.redeem(shares, receiver, address(this));

        assertEq(assets, expectedAssets, "assets != expected");

        if (approveMax) {
            assertEq(vault.allowance(address(this), spender), type(uint256).max, "approve max");
        } else if (address(this) == spender) {
            assertEq(vault.allowance(address(this), spender), sharesApproved, "self approved");
        } else {
            assertEq(vault.allowance(address(this), spender), sharesApproved - shares, "approved-redeemed");
        }

        assertEq(underlyingToken.balanceOf(address(vault)), totalAssetsAfterInterest - assets, "balanceOf(vault)");
        assertEq(underlyingToken.balanceOf(receiver), assets, "balanceOf(receiver)");
        assertEq(vault.balanceOf(address(this)), initialSharesDeposit - shares, "balanceOf(this)");
        assertEq(vault.totalSupply(), initialSharesDeposit - shares, "totalSupply");
    }

    function testWithdraw(uint256 assets, uint256 sharesApproved, address receiver, address spender, bool approveMax)
        public
    {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(vault));
        assets = bound(assets, 0, INITIAL_DEPOSIT);

        uint256 expectedShares = assets.mulDivUp(vault.totalSupply() + vault.virtualShares(), vault.totalAssets() + 1);
        uint256 previewedShares = vault.previewWithdraw(assets);
        assertEq(previewedShares, expectedShares, "previewedShares != expected");

        sharesApproved = bound(sharesApproved, previewedShares, previewedShares * 2 + 1);
        vault.approve(spender, approveMax ? type(uint256).max : sharesApproved);

        vm.expectEmit();
        emit EventsLib.Withdraw(spender, receiver, address(this), assets, expectedShares);

        vm.prank(spender);
        uint256 shares = vault.withdraw(assets, receiver, address(this));

        assertEq(shares, expectedShares, "shares != expected");

        if (approveMax) {
            assertEq(vault.allowance(address(this), spender), type(uint256).max, "approve max");
        } else if (address(this) == spender) {
            assertEq(vault.allowance(address(this), spender), sharesApproved, "self approved");
        } else {
            assertEq(vault.allowance(address(this), spender), sharesApproved - shares, "approved-redeemed");
        }

        assertEq(underlyingToken.balanceOf(address(vault)), totalAssetsAfterInterest - assets, "balanceOf(vault)");
        assertEq(underlyingToken.balanceOf(receiver), assets, "balanceOf(receiver)");
        assertEq(vault.balanceOf(address(this)), initialSharesDeposit - shares, "balanceOf(this)");
        assertEq(vault.totalSupply(), initialSharesDeposit - shares, "totalSupply");
    }
}
