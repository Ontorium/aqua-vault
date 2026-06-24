// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "../lib/forge-std/src/Test.sol";
import {GateExample, IBundler3} from "./examples/GateExample.sol";

contract Bundler3Mock {
    address private _initiator;

    constructor(address initiator_) {
        _initiator = initiator_;
    }

    function initiator() external view returns (address) {
        return _initiator;
    }
}

contract BundlerAdapterMock {
    IBundler3 private _bundler3;

    constructor(IBundler3 bundler3_) {
        _bundler3 = bundler3_;
    }

    function BUNDLER3() external view returns (IBundler3) {
        return _bundler3;
    }
}

contract GateExampleTest is Test {
    GateExample gate;
    address gateOwner;

    function setUp() public {
        gateOwner = makeAddr("gateOwner");
        gate = new GateExample(gateOwner);
    }

    function testConstructor() public view {
        assertEq(gate.owner(), gateOwner);
    }

    function testOwnerOperations(address newOwner, address nonOwner) public {
        vm.assume(newOwner != address(0));
        vm.assume(nonOwner != address(0) && nonOwner != gateOwner);

        vm.prank(nonOwner);
        vm.expectRevert(GateExample.Unauthorized.selector);
        gate.setOwner(newOwner);

        vm.prank(gateOwner);
        gate.setOwner(newOwner);
        assertEq(gate.owner(), newOwner);
    }

    function testWhitelistOperations(address account, bool isWhitelisted, address nonOwner) public {
        vm.assume(account != address(0));
        vm.assume(nonOwner != address(0) && nonOwner != gateOwner);

        vm.prank(nonOwner);
        vm.expectRevert(GateExample.Unauthorized.selector);
        gate.setIsWhitelisted(account, isWhitelisted);

        vm.prank(gateOwner);
        gate.setIsWhitelisted(account, isWhitelisted);
        assertEq(gate.whitelisted(account), isWhitelisted);

        assertEq(gate.canSendShares(account), isWhitelisted);
        assertEq(gate.canReceiveAssets(account), isWhitelisted);
        assertEq(gate.canReceiveShares(account), isWhitelisted);
        assertEq(gate.canSendAssets(account), isWhitelisted);
    }

    function testBundlerAdapterOperations(address adapterAddr, bool isAdapter, address nonOwner) public {
        vm.assume(adapterAddr != address(0));
        vm.assume(nonOwner != address(0) && nonOwner != gateOwner);

        vm.prank(nonOwner);
        vm.expectRevert(GateExample.Unauthorized.selector);
        gate.setIsBundlerAdapter(adapterAddr, isAdapter);

        vm.prank(gateOwner);
        gate.setIsBundlerAdapter(adapterAddr, isAdapter);
        assertEq(gate.isBundlerAdapter(adapterAddr), isAdapter);
    }

    function testAdapterWithWhitelistedInitiator(address initiatorAddr, bool isWhitelisted) public {
        vm.assume(initiatorAddr != address(0));

        address bundlerAddr = address(new Bundler3Mock(initiatorAddr));
        address adapterAddr = address(new BundlerAdapterMock(IBundler3(bundlerAddr)));

        vm.prank(gateOwner);
        gate.setIsWhitelisted(initiatorAddr, isWhitelisted);

        // Adapter not registered yet -> always false.
        assertFalse(gate.canSendShares(adapterAddr));
        assertFalse(gate.canReceiveAssets(adapterAddr));
        assertFalse(gate.canReceiveShares(adapterAddr));
        assertFalse(gate.canSendAssets(adapterAddr));

        vm.prank(gateOwner);
        gate.setIsBundlerAdapter(adapterAddr, true);

        // After registration, gate mirrors the initiator's whitelist status.
        assertEq(gate.canSendShares(adapterAddr), isWhitelisted);
        assertEq(gate.canReceiveAssets(adapterAddr), isWhitelisted);
        assertEq(gate.canReceiveShares(adapterAddr), isWhitelisted);
        assertEq(gate.canSendAssets(adapterAddr), isWhitelisted);
    }
}
