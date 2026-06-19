// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {
    IReceiveSharesGate,
    ISendSharesGate,
    IReceiveAssetsGate,
    ISendAssetsGate
} from "../src/interfaces/IGate.sol";

contract GatingTest is BaseTest {
    address gate;
    address sharesReceiver;
    address assetsSender;
    address sharesSender;
    address assetsReceiver;
    uint256 constant TEST_ASSETS = 1e18;

    function setUp() public override {
        super.setUp();

        gate = makeAddr("gate");
        sharesReceiver = makeAddr("sharesReceiver");
        assetsSender = makeAddr("assetsSender");
        sharesSender = makeAddr("sharesSender");
        assetsReceiver = makeAddr("assetsReceiver");
    }

    function _setAllGates() internal {
        vm.startPrank(governance);
        vault.setReceiveSharesGate(gate);
        vault.setReceiveAssetsGate(gate);
        vault.setSendSharesGate(gate);
        vault.setSendAssetsGate(gate);
        vm.stopPrank();
    }

    function testNoGateDefaultsToAllow() public {
        // With gates unset, zero-value entry/exit must succeed without permission checks.
        vault.deposit(0, address(this));
        vault.mint(0, address(this));
        vault.withdraw(0, address(this), address(this));
        vault.redeem(0, address(this), address(this));
    }

    function testCannotReceiveSharesOnDeposit() public {
        _setAllGates();
        vm.mockCall(gate, abi.encodeCall(IReceiveSharesGate.canReceiveShares, (sharesReceiver)), abi.encode(false));
        vm.mockCall(gate, abi.encodeCall(ISendAssetsGate.canSendAssets, (assetsSender)), abi.encode(true));

        vm.expectRevert(ErrorsLib.CannotReceiveShares.selector);
        vm.prank(assetsSender);
        vault.deposit(0, sharesReceiver);
    }

    function testCannotSendAssetsOnDeposit() public {
        _setAllGates();
        vm.mockCall(gate, abi.encodeCall(IReceiveSharesGate.canReceiveShares, (sharesReceiver)), abi.encode(true));
        vm.mockCall(gate, abi.encodeCall(ISendAssetsGate.canSendAssets, (assetsSender)), abi.encode(false));

        vm.expectRevert(ErrorsLib.CannotSendAssets.selector);
        vm.prank(assetsSender);
        vault.deposit(0, sharesReceiver);
    }

    function testCannotSendSharesOnRedeem() public {
        _setAllGates();
        vm.mockCall(gate, abi.encodeCall(ISendSharesGate.canSendShares, (sharesSender)), abi.encode(false));
        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (assetsReceiver)), abi.encode(true));

        vm.expectRevert(ErrorsLib.CannotSendShares.selector);
        vm.prank(sharesSender);
        vault.redeem(0, assetsReceiver, sharesSender);
    }

    function testCannotReceiveAssetsOnRedeem() public {
        _setAllGates();
        vm.mockCall(gate, abi.encodeCall(ISendSharesGate.canSendShares, (sharesSender)), abi.encode(true));
        vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (assetsReceiver)), abi.encode(false));

        vm.expectRevert(ErrorsLib.CannotReceiveAssets.selector);
        vm.prank(sharesSender);
        vault.redeem(0, assetsReceiver, sharesSender);
    }


    function testTransferRequiresSendShares() public {
        _setAllGates();
        vm.mockCall(gate, abi.encodeCall(ISendSharesGate.canSendShares, (sharesSender)), abi.encode(false));
        vm.mockCall(gate, abi.encodeCall(IReceiveSharesGate.canReceiveShares, (sharesReceiver)), abi.encode(true));

        vm.expectRevert(ErrorsLib.CannotSendShares.selector);
        vm.prank(sharesSender);
        vault.transfer(sharesReceiver, 0);
    }

    function testTransferRequiresReceiveShares() public {
        _setAllGates();
        vm.mockCall(gate, abi.encodeCall(ISendSharesGate.canSendShares, (sharesSender)), abi.encode(true));
        vm.mockCall(gate, abi.encodeCall(IReceiveSharesGate.canReceiveShares, (sharesReceiver)), abi.encode(false));

        vm.expectRevert(ErrorsLib.CannotReceiveShares.selector);
        vm.prank(sharesSender);
        vault.transfer(sharesReceiver, 0);
    }

    function testTransferFromRequiresSendShares() public {
        _setAllGates();
        vm.mockCall(gate, abi.encodeCall(ISendSharesGate.canSendShares, (sharesSender)), abi.encode(false));
        vm.mockCall(gate, abi.encodeCall(IReceiveSharesGate.canReceiveShares, (sharesReceiver)), abi.encode(true));

        vm.expectRevert(ErrorsLib.CannotSendShares.selector);
        vm.prank(sharesSender);
        vault.transferFrom(sharesSender, sharesReceiver, 0);
    }

    function testTransferFromRequiresReceiveShares() public {
        _setAllGates();
        vm.mockCall(gate, abi.encodeCall(ISendSharesGate.canSendShares, (sharesSender)), abi.encode(true));
        vm.mockCall(gate, abi.encodeCall(IReceiveSharesGate.canReceiveShares, (sharesReceiver)), abi.encode(false));

        vm.expectRevert(ErrorsLib.CannotReceiveShares.selector);
        vm.prank(sharesReceiver);
        vault.transferFrom(sharesSender, sharesReceiver, 0);
    }

    function testCanSendSharesPassthrough(bool hasGate, bool can) public {
        if (hasGate) {
            _setAllGates();
            vm.mockCall(gate, abi.encodeCall(ISendSharesGate.canSendShares, (sharesSender)), abi.encode(can));
        }
        assertEq(vault.canSendShares(sharesSender), !hasGate || can);
    }

    function testCanReceiveSharesPassthrough(bool hasGate, bool can) public {
        if (hasGate) {
            _setAllGates();
            vm.mockCall(gate, abi.encodeCall(IReceiveSharesGate.canReceiveShares, (sharesSender)), abi.encode(can));
        }
        assertEq(vault.canReceiveShares(sharesSender), !hasGate || can);
    }

    function testCanSendAssetsPassthrough(bool hasGate, bool can) public {
        if (hasGate) {
            _setAllGates();
            vm.mockCall(gate, abi.encodeCall(ISendAssetsGate.canSendAssets, (assetsSender)), abi.encode(can));
        }
        assertEq(vault.canSendAssets(assetsSender), !hasGate || can);
    }

    function testCanReceiveAssetsPassthrough(bool hasGate, bool can) public {
        // canReceiveAssets has a hardcoded `account == address(this)` short-circuit; use a different addr.
        if (hasGate) {
            _setAllGates();
            vm.mockCall(gate, abi.encodeCall(IReceiveAssetsGate.canReceiveAssets, (assetsSender)), abi.encode(can));
        }
        assertEq(vault.canReceiveAssets(assetsSender), !hasGate || can);
    }
}
