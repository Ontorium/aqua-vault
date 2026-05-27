// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract ERC20Test is BaseTest {
    using stdStorage for StdStorage;

    uint256 constant MAX_TEST_SHARES = 1e36;

    struct PermitInfo {
        uint256 privateKey;
        uint256 nonce;
        uint256 deadline;
    }

    function _signPermit(uint256 privateKey, address _owner, address to, uint256 shares, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 hashStruct = keccak256(abi.encode(PERMIT_TYPEHASH, _owner, to, shares, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), hashStruct));
        return vm.sign(privateKey, digest);
    }

    function _setupPermit(PermitInfo calldata p)
        internal
        view
        returns (address _owner, uint256 privateKey, uint256 nonce, uint256 deadline)
    {
        privateKey = boundPrivateKey(p.privateKey);
        _owner = vm.addr(privateKey);
        deadline = bound(p.deadline, block.timestamp, type(uint256).max);
        nonce = bound(p.nonce, 0, type(uint256).max - 1);
    }

    function _setCurrentNonce(address _owner, uint256 nonce) internal {
        stdstore.target(address(vault)).sig("nonces(address)").with_key(_owner).checked_write(nonce);
    }

    function setUp() public override {
        super.setUp();

        // Fund this contract and approve the vault. Mint via the mock so totalSupply tracks.
        underlyingToken.mint(address(this), type(uint128).max);
        underlyingToken.approve(address(vault), type(uint256).max);
    }

    function testCreateShares(uint256 shares) public {
        shares = bound(shares, 0, MAX_TEST_SHARES);

        vm.expectEmit();
        emit EventsLib.Transfer(address(0), address(this), shares);

        vault.mint(shares, address(this));
        assertEq(vault.totalSupply(), shares, "total supply");
        assertEq(vault.balanceOf(address(this)), shares, "balance");
    }

    function testCreateSharesZeroAddress(uint256 shares) public {
        // Bound to the funded balance so the asset transfer succeeds and ZeroAddress is the first revert reached.
        shares = bound(shares, 0, MAX_TEST_SHARES);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vault.mint(shares, address(0));
    }

    function testDeleteShares(uint256 shares, uint256 sharesRedeemed) public {
        shares = bound(shares, 0, MAX_TEST_SHARES);
        sharesRedeemed = bound(sharesRedeemed, 0, shares);

        vault.mint(shares, address(this));
        vm.expectEmit();
        emit EventsLib.Transfer(address(this), address(0), sharesRedeemed);

        vault.redeem(sharesRedeemed, address(this), address(this));

        assertEq(vault.totalSupply(), shares - sharesRedeemed, "total supply");
        assertEq(vault.balanceOf(address(this)), shares - sharesRedeemed, "balance");
    }

    function testDeleteSharesZeroAddress() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vault.redeem(0, address(this), address(0));
    }

    function testApprove(address spender, uint256 shares) public {
        shares = bound(shares, 0, MAX_TEST_SHARES);
        vm.expectEmit();
        emit EventsLib.Approval(address(this), spender, shares);

        assertTrue(vault.approve(spender, shares));
        assertEq(vault.allowance(address(this), spender), shares);
    }

    function testTransfer(address to, uint256 shares, uint256 sharesTransferred) public {
        shares = bound(shares, 0, MAX_TEST_SHARES);
        vm.assume(to != address(0));
        sharesTransferred = bound(sharesTransferred, 0, shares);

        vault.mint(shares, address(this));

        vm.expectEmit();
        emit EventsLib.Transfer(address(this), to, sharesTransferred);

        assertTrue(vault.transfer(to, sharesTransferred));

        assertEq(vault.totalSupply(), shares, "total supply");
        if (address(this) == to) {
            assertEq(vault.balanceOf(address(this)), shares, "balance");
        } else {
            assertEq(vault.balanceOf(address(this)), shares - sharesTransferred, "balance from");
            assertEq(vault.balanceOf(to), sharesTransferred, "balance to");
        }
    }

    function testTransferZeroAddress(uint256 shares) public {
        shares = bound(shares, 0, MAX_TEST_SHARES);
        vault.mint(shares, address(this));
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vault.transfer(address(0), shares);
    }

    function testTransferFrom(
        address from,
        address to,
        uint256 shares,
        uint256 sharesTransferred,
        uint256 sharesApproved
    ) public {
        shares = bound(shares, 0, MAX_TEST_SHARES);
        sharesApproved = bound(sharesApproved, 0, shares);
        sharesTransferred = bound(sharesTransferred, 0, sharesApproved);

        vm.assume(from != address(0));
        vm.assume(to != address(0));
        vault.mint(shares, from);

        vm.prank(from);
        vault.approve(address(this), sharesApproved);

        if (address(this) != from) {
            vm.expectEmit();
            emit EventsLib.AllowanceUpdatedByTransferFrom(from, address(this), sharesApproved - sharesTransferred);
        }

        vm.expectEmit();
        emit EventsLib.Transfer(from, to, sharesTransferred);

        vault.transferFrom(from, to, sharesTransferred);

        if (address(this) != from) {
            assertEq(vault.allowance(from, address(this)), sharesApproved - sharesTransferred, "approved-transferred");
        } else {
            assertEq(vault.allowance(from, address(this)), sharesApproved, "approved");
        }
        if (from == to) {
            assertEq(vault.balanceOf(from), shares, "balance");
        } else {
            assertEq(vault.balanceOf(from), shares - sharesTransferred, "balance from");
            assertEq(vault.balanceOf(to), sharesTransferred, "balance to");
        }
    }

    function testTransferFromSenderZeroAddress(address to) public {
        vm.assume(to != address(0));
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vault.transferFrom(address(0), to, 0);
    }

    function testTransferFromReceiverZeroAddress(address from, uint256 shares) public {
        shares = bound(shares, 0, MAX_TEST_SHARES);
        vm.assume(from != address(0));
        vault.mint(shares, from);
        vm.prank(from);
        vault.approve(address(this), type(uint256).max);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vault.transferFrom(from, address(0), shares);
    }

    function testInfiniteApproveTransferFrom(address from, address to, uint256 shares, uint256 sharesTransferred)
        public
    {
        shares = bound(shares, 0, MAX_TEST_SHARES);
        sharesTransferred = bound(sharesTransferred, 0, shares);

        vm.assume(from != address(0));
        vm.assume(to != address(0));
        vault.mint(shares, from);

        vm.prank(from);
        vault.approve(address(this), type(uint256).max);

        vm.expectEmit();
        emit EventsLib.Transfer(from, to, sharesTransferred);

        vault.transferFrom(from, to, sharesTransferred);
        assertEq(vault.allowance(from, address(this)), type(uint256).max, "allowance");
        if (from == to) {
            assertEq(vault.balanceOf(from), shares, "balance");
        } else {
            assertEq(vault.balanceOf(from), shares - sharesTransferred, "balance from");
            assertEq(vault.balanceOf(to), sharesTransferred, "balance to");
        }
    }

    function testPermitOK(PermitInfo calldata p, address to, uint256 shares) public {
        (address _owner, uint256 privateKey, uint256 nonce, uint256 deadline) = _setupPermit(p);
        _setCurrentNonce(_owner, nonce);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(privateKey, _owner, to, shares, nonce, deadline);

        vm.expectEmit();
        emit EventsLib.Approval(_owner, to, shares);
        vm.expectEmit();
        emit EventsLib.Permit(_owner, to, shares, nonce, deadline);

        vault.permit(_owner, to, shares, deadline, v, r, s);
        assertEq(vault.allowance(_owner, to), shares);
        assertEq(vault.nonces(_owner), nonce + 1);
    }

    function testPermitBadOwnerReverts(PermitInfo calldata p, address to, uint256 shares, address badOwner) public {
        (address _owner, uint256 privateKey, uint256 nonce, uint256 deadline) = _setupPermit(p);
        _setCurrentNonce(_owner, nonce);

        vm.assume(_owner != badOwner);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(privateKey, badOwner, to, shares, nonce, deadline);

        vm.expectRevert(ErrorsLib.InvalidSigner.selector);
        vault.permit(_owner, to, shares, deadline, v, r, s);
    }

    function testPermitBadSpenderReverts(PermitInfo calldata p, address to, uint256 shares, address badSpender) public {
        (address _owner, uint256 privateKey, uint256 nonce, uint256 deadline) = _setupPermit(p);
        _setCurrentNonce(_owner, nonce);

        vm.assume(to != badSpender);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(privateKey, _owner, badSpender, shares, nonce, deadline);

        vm.expectRevert(ErrorsLib.InvalidSigner.selector);
        vault.permit(_owner, to, shares, deadline, v, r, s);
    }

    function testPermitBadNonceReverts(PermitInfo calldata p, address to, uint256 shares, uint256 badNonce) public {
        (address _owner, uint256 privateKey, uint256 nonce, uint256 deadline) = _setupPermit(p);
        _setCurrentNonce(_owner, nonce);

        vm.assume(nonce != badNonce);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(privateKey, _owner, to, shares, badNonce, deadline);

        vm.expectRevert(ErrorsLib.InvalidSigner.selector);
        vault.permit(_owner, to, shares, deadline, v, r, s);
    }

    function testPermitBadDeadlineReverts(PermitInfo calldata p, address to, uint256 shares, uint256 badDeadline)
        public
    {
        (address _owner, uint256 privateKey, uint256 nonce, uint256 deadline) = _setupPermit(p);
        _setCurrentNonce(_owner, nonce);

        badDeadline = bound(badDeadline, block.timestamp, type(uint256).max - 1);
        vm.assume(badDeadline != deadline);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(privateKey, _owner, to, shares, nonce, badDeadline);

        vm.expectRevert(ErrorsLib.InvalidSigner.selector);
        vault.permit(_owner, to, shares, deadline, v, r, s);
    }

    function testPermitPastDeadlineReverts(PermitInfo calldata p, address to, uint256 shares) public {
        (address _owner, uint256 privateKey, uint256 nonce, uint256 deadline) = _setupPermit(p);
        _setCurrentNonce(_owner, nonce);

        deadline = bound(deadline, 0, block.timestamp - 1);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(privateKey, _owner, to, shares, nonce, deadline);

        vm.expectRevert(ErrorsLib.PermitDeadlineExpired.selector);
        vault.permit(_owner, to, shares, deadline, v, r, s);
    }

    function testPermitReplayReverts(PermitInfo calldata p, address to, uint256 shares) public {
        (address _owner, uint256 privateKey, uint256 nonce, uint256 deadline) = _setupPermit(p);
        nonce = bound(nonce, 0, type(uint256).max - 2);
        _setCurrentNonce(_owner, nonce);

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(privateKey, _owner, to, shares, nonce, deadline);

        vault.permit(_owner, to, shares, deadline, v, r, s);
        vm.expectRevert(ErrorsLib.InvalidSigner.selector);
        vault.permit(_owner, to, shares, deadline, v, r, s);
    }
}
