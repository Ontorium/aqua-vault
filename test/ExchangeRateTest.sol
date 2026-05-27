// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract ExchangeRateTest is BaseTest {
    uint256 constant INITIAL_DEPOSIT = 1e24;
    uint256 internal maxTestAssets;
    uint256 internal totalAssetsValue;
    uint256 internal totalSupplyValue;

    function setUp() public override {
        super.setUp();

        maxTestAssets = 10 ** min(18 + underlyingToken.decimals(), 36);

        underlyingToken.mint(address(this), type(uint128).max);
        underlyingToken.approve(address(vault), type(uint256).max);

        vault.deposit(INITIAL_DEPOSIT, address(this));

        assertEq(underlyingToken.balanceOf(address(vault)), INITIAL_DEPOSIT, "balance before");
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT, "totalAssets before");

        // Donate another tranche of underlying then force-stamp _totalAssets so the share price doubles.
        underlyingToken.transfer(address(vault), INITIAL_DEPOSIT);
        _writeTotalAssets(2 * INITIAL_DEPOSIT);

        totalAssetsValue = vault.totalAssets();
        totalSupplyValue = vault.totalSupply();

        assertEq(underlyingToken.balanceOf(address(vault)), 2 * INITIAL_DEPOSIT, "balance after");
        assertEq(vault.totalAssets(), 2 * INITIAL_DEPOSIT, "totalAssets after");
        assertEq(vault.totalSupply(), INITIAL_DEPOSIT * vault.virtualShares(), "totalSupply");
    }

    function testVirtualShares() public view {
        uint256 underlyingDecimals = underlyingToken.decimals();
        assertEq(vault.virtualShares(), 10 ** (underlyingDecimals <= 18 ? 18 - underlyingDecimals : 0));
    }

    function testDecimals() public view {
        uint256 underlyingDecimals = underlyingToken.decimals();
        assertEq(vault.decimals(), underlyingDecimals <= 18 ? 18 : underlyingDecimals);
    }

    function testExchangeRateRedeem(uint256 shares) public {
        shares = bound(shares, 0, vault.balanceOf(address(this)));
        uint256 assets = vault.redeem(shares, address(this), address(this));
        assertEq(assets, shares * (totalAssetsValue + 1) / (totalSupplyValue + vault.virtualShares()));
    }

    function testExchangeRateWithdraw(uint256 assets) public {
        assets = bound(assets, 0, INITIAL_DEPOSIT);
        uint256 shares = vault.withdraw(assets, address(this), address(this));
        assertApproxEqAbs(shares, assets * (totalSupplyValue + vault.virtualShares()) / (totalAssetsValue + 1), 1);
    }

    function testExchangeRateMint(uint256 shares) public {
        shares = bound(shares, 0, maxTestAssets);
        uint256 assets = vault.mint(shares, address(this));
        assertApproxEqAbs(assets, shares * (totalAssetsValue + 1) / (totalSupplyValue + vault.virtualShares()), 1);
    }

    function testExchangeRateDeposit(uint256 assets) public {
        assets = bound(assets, 0, maxTestAssets);
        uint256 shares = vault.deposit(assets, address(this));
        assertEq(shares, assets * (totalSupplyValue + vault.virtualShares()) / (totalAssetsValue + 1));
    }
}
