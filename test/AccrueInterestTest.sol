// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract AccrueInterestTest is BaseTest {
    using MathLib for uint256;

    address performanceFeeRecipient = makeAddr("performanceFeeRecipient");
    address managementFeeRecipient = makeAddr("managementFeeRecipient");
    uint256 maxTestAssets;
    StrategyMock strategy;

    function setUp() public override {
        super.setUp();

        maxTestAssets = 10 ** min(18 + underlyingToken.decimals(), 36);

        vm.startPrank(governance);
        vault.setPerformanceFeeRecipient(performanceFeeRecipient);
        vault.setManagementFeeRecipient(managementFeeRecipient);
        vault.setMaxRate(MAX_MAX_RATE);
        vm.stopPrank();

        underlyingToken.mint(address(this), type(uint128).max);
        underlyingToken.approve(address(vault), type(uint256).max);

        strategy = _addStrategyWithMaxCaps();
    }

    /// forge-config: default.isolate = true
    function testAccrueInterestView(
        uint256 deposit,
        uint256 performanceFee,
        uint256 managementFee,
        uint256 interest,
        uint256 elapsed
    ) public {
        deposit = bound(deposit, 0, maxTestAssets);
        performanceFee = bound(performanceFee, 0, MAX_PERFORMANCE_FEE);
        managementFee = bound(managementFee, 0, MAX_MANAGEMENT_FEE);
        elapsed = bound(elapsed, 0, 10 * 365 days);
        interest = bound(interest, 0, maxTestAssets);

        strategy.setInterest(interest);
        vm.startPrank(governance);
        vault.setPerformanceFee(performanceFee);
        vault.setManagementFee(managementFee);
        vm.stopPrank();

        vault.deposit(deposit, address(this));
        skip(elapsed);

        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = vault.accrueInterestView();
        vault.accrueInterest();
        assertEq(newTotalAssets, vault._totalAssets());
        assertEq(performanceFeeShares, vault.balanceOf(performanceFeeRecipient));
        assertEq(managementFeeShares, vault.balanceOf(managementFeeRecipient));
    }

    /// forge-config: default.isolate = true
    function testTotalAssetsConsistency(uint256 deposit, uint256 interest, uint256 elapsed) public {
        deposit = bound(deposit, 0, maxTestAssets);
        elapsed = bound(elapsed, 0, 10 * 365 days);
        interest = bound(interest, 0, maxTestAssets);

        strategy.setInterest(interest);
        vault.deposit(deposit, address(this));
        skip(elapsed);

        uint256 expected = vault.totalAssets();
        vault.accrueInterest();
        assertEq(expected, vault._totalAssets());
    }

    /// forge-config: default.isolate = true
    function testAccrueInterestEmits(
        uint256 deposit,
        uint256 performanceFee,
        uint256 managementFee,
        uint256 interest,
        uint256 elapsed
    ) public {
        performanceFee = bound(performanceFee, 0, MAX_PERFORMANCE_FEE);
        managementFee = bound(managementFee, 0, MAX_MANAGEMENT_FEE);
        deposit = bound(deposit, 1, maxTestAssets);
        elapsed = bound(elapsed, 1, 10 * 365 days);
        interest = bound(interest, 0, (deposit * MAX_MAX_RATE).mulDivDown(elapsed, WAD));

        vault.deposit(deposit, address(this));
        vm.startPrank(governance);
        vault.setPerformanceFee(performanceFee);
        vault.setManagementFee(managementFee);
        vm.stopPrank();

        // Move funds to the strategy so post-interest realAssets > _totalAssets.
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);
        strategy.setInterest(interest);

        skip(elapsed);

        vm.expectEmit(false, false, false, false);
        emit EventsLib.AccrueInterest(0, 0, 0, 0);
        vault.accrueInterest();
        assertEq(vault.totalAssets(), deposit + interest, "totalAssets");
    }

    /// forge-config: default.isolate = true
    function testAccrueInterestMaxRateClamps(uint256 deposit, uint256 interest, uint256 elapsed) public {
        deposit = bound(deposit, 0, maxTestAssets);
        interest = bound(interest, 0, maxTestAssets);
        elapsed = bound(elapsed, 0, 10 * 365 days);

        vault.deposit(deposit, address(this));
        strategy.setInterest(interest);
        skip(elapsed);

        vault.accrueInterest();
        assertLe(vault.totalAssets(), deposit + (deposit * elapsed).mulDivDown(MAX_MAX_RATE, WAD));
    }

    /// forge-config: default.isolate = true
    function testAccrueInterestDonationNoSkip(uint256 deposit, uint256 donation) public {
        deposit = bound(deposit, 0, maxTestAssets);
        donation = bound(donation, 0, maxTestAssets);

        vault.deposit(deposit, address(this));
        underlyingToken.transfer(address(vault), donation);

        // Without elapsed time, maxRate does not allow any growth.
        assertEq(vault.totalAssets(), deposit);
    }

    /// forge-config: default.isolate = true
    function testAccrueInterestDonationSkip(uint256 deposit, uint256 donation, uint256 elapsed) public {
        deposit = bound(deposit, 0, maxTestAssets);
        donation = bound(donation, 0, maxTestAssets);
        elapsed = bound(elapsed, 0, 10 * 365 days);

        vault.deposit(deposit, address(this));
        skip(elapsed);
        underlyingToken.transfer(address(vault), donation);

        uint256 maxTotalAssets = deposit + (deposit * elapsed).mulDivDown(MAX_MAX_RATE, WAD);
        assertEq(vault.totalAssets(), MathLib.min(deposit + donation, maxTotalAssets));
    }

    /// forge-config: default.isolate = false
    function testFirstTotalAssetsTransientness(uint256 deposit) public {
        deposit = bound(deposit, 1, maxTestAssets);

        // Transient resets per tx; reads outside a vault entry call must be 0.
        assertEq(vault.firstTotalAssets(), 0);

        vault.deposit(deposit, address(this));
        // Outside the tx that just ran, transient is again 0.
        assertEq(vault.firstTotalAssets(), 0);
    }
}
