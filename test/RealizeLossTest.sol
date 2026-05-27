// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

struct Call {
    address target;
    bytes data;
}

contract RealizeLossTest is BaseTest {
    StrategyMock internal strategy;
    uint256 maxTestAmount;

    function setUp() public override {
        super.setUp();

        maxTestAmount = 10 ** min(18 + underlyingToken.decimals(), 36);

        strategy = _addStrategyWithMaxCaps();

        underlyingToken.mint(address(this), type(uint128).max);
        underlyingToken.approve(address(vault), type(uint256).max);
    }

    /// forge-config: default.isolate = true
    function testRealizeLoss(uint256 deposit, uint256 expectedLoss) public {
        deposit = bound(deposit, 1, maxTestAmount);
        expectedLoss = bound(expectedLoss, 1, deposit);

        vault.deposit(deposit, address(this));
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);
        strategy.setLoss(expectedLoss);

        vm.expectEmit();
        emit EventsLib.AccrueInterest(deposit, deposit - expectedLoss, 0, 0);
        vault.accrueInterest();
        assertEq(vault.totalAssets(), deposit - expectedLoss, "totalAssets decreased by loss");
    }

    /// forge-config: default.isolate = true
    function testTouchThenLoss(uint256 deposit, uint256 expectedLoss) public {
        deposit = bound(deposit, 1, maxTestAmount);
        expectedLoss = bound(expectedLoss, 1, deposit);

        vault.deposit(deposit, address(this));
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        Call[] memory calls = new Call[](3);
        calls[0] = Call({target: address(vault), data: abi.encodeCall(Vault.accrueInterest, ())});
        calls[1] = Call({target: address(strategy), data: abi.encodeCall(StrategyMock.setLoss, (expectedLoss))});
        calls[2] = Call({target: address(vault), data: abi.encodeWithSignature("totalAssets()")});
        bytes[] memory results = this._batch(calls);
        uint256 totalAssets = abi.decode(results[2], (uint256));
        // The cached firstTotalAssets means a later read inside the same tx must not pick up the new loss.
        assertEq(totalAssets, deposit, "totalAssets should not have changed mid-tx");
    }

    /// forge-config: default.isolate = true
    function testLossThenTouch(uint256 deposit, uint256 expectedLoss) public {
        deposit = bound(deposit, 1, maxTestAmount);
        expectedLoss = bound(expectedLoss, 1, deposit);

        vault.deposit(deposit, address(this));
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: address(strategy), data: abi.encodeCall(StrategyMock.setLoss, (expectedLoss))});
        calls[1] = Call({target: address(vault), data: abi.encodeWithSignature("totalAssets()")});
        bytes[] memory results = this._batch(calls);
        uint256 totalAssets = abi.decode(results[1], (uint256));
        assertEq(totalAssets, deposit - expectedLoss, "totalAssets should reflect loss");
    }

    function testAllocationLossViaAllocate(uint256 deposit, uint256 expectedLoss) public {
        deposit = bound(deposit, 1, maxTestAmount);
        expectedLoss = bound(expectedLoss, 1, deposit);

        vault.deposit(deposit, address(this));
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", deposit);

        strategy.setLoss(expectedLoss);

        // Touching with a zero-asset allocation realises the loss in the cap accounting.
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", 0);

        bytes32 id0 = strategy.ID_0();
        assertEq(strategyManager.allocation(id0), deposit - expectedLoss, "id-0 allocation reduced by loss");
    }

    function _batch(Call[] calldata calls) external returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory result) = calls[i].target.call(calls[i].data);
            if (!success) revert(string(result));
            results[i] = result;
        }
    }
}
