// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {IReceiveAssetsGate} from "../src/interfaces/IGate.sol";

contract ForceDeallocateTest is BaseTest {
    using MathLib for uint256;

    uint256 maxTestAssets;
    StrategyMock strategy;

    function setUp() public override {
        super.setUp();

        maxTestAssets = 10 ** min(18 + underlyingToken.decimals(), 36);

        strategy = _addStrategyWithMaxCaps();

        underlyingToken.mint(address(this), type(uint128).max);
        underlyingToken.approve(address(vault), type(uint256).max);
    }

    function testForceDeallocate(uint256 supplied, uint256 deallocated, uint256 penaltyBps) public {
        supplied = bound(supplied, 1, maxTestAssets);
        deallocated = bound(deallocated, 0, supplied);
        penaltyBps = bound(penaltyBps, 0, MAX_FORCE_DEALLOCATE_PENALTY);

        uint256 shares = vault.deposit(supplied, address(this));
        assertEq(underlyingToken.balanceOf(address(vault)), supplied);

        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", supplied);
        assertEq(underlyingToken.balanceOf(address(strategy)), supplied);

        vm.prank(governance);
        strategyManager.setForceDeallocatePenalty(address(strategy), penaltyBps);

        uint256 penaltyAssets = deallocated.mulDivUp(penaltyBps, WAD);
        uint256 expectedRemainingShares = shares - vault.previewWithdraw(penaltyAssets);

        bytes32[] memory expectedIds = new bytes32[](2);
        expectedIds[0] = strategy.ID_0();
        expectedIds[1] = strategy.ID_1();

        vm.expectEmit();
        emit EventsLib.ForceDeallocate(
            address(this), address(strategy), deallocated, address(this), expectedIds, penaltyAssets
        );
        uint256 withdrawnShares =
            vault.forceDeallocate(address(strategy), hex"", deallocated, address(this));

        assertEq(strategy.recordedSelector(), Vault.forceDeallocate.selector, "selector");
        assertEq(strategy.recordedSender(), address(this), "sender");
        assertEq(shares - expectedRemainingShares, withdrawnShares, "withdrawnShares");
        assertEq(underlyingToken.balanceOf(address(strategy)), supplied - deallocated, "balanceOf(strategy)");
        assertEq(underlyingToken.balanceOf(address(vault)), deallocated, "balanceOf(vault)");
        assertEq(vault.balanceOf(address(this)), expectedRemainingShares, "balanceOf(this)");
    }

    function testForceDeallocateWithBlockedVaultStillWorks() public {
        address gate = makeAddr("gate");
        vm.prank(governance);
        vault.setReceiveAssetsGate(gate);
        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (address(vault))), abi.encode(false));

        uint256 penalty = 0.01e18; // 1%
        vm.prank(governance);
        strategyManager.setForceDeallocatePenalty(address(strategy), penalty);

        underlyingToken.mint(address(this), 1000);
        underlyingToken.approve(address(vault), 1000);
        vault.deposit(1000, address(this));
        vm.prank(allocator);
        vault.allocate(address(strategy), hex"", 1000);

        // Force deallocate must succeed even though the gate blocks transfers back to the vault address itself.
        vault.forceDeallocate(address(strategy), hex"", 100, address(this));
    }
}
