// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ERC20Mock} from "./ERC20Mock.sol";

/// @notice Minimal rebasing aToken used by AquaStrategy tests. `balanceOf` tracks supplied principal
/// and can be grown via `accrue` to simulate Aave interest. The underlying liquidity backing the
/// market is held at this contract's address (matching real Aave, where AquaStrategy reads
/// `underlying.balanceOf(aToken)` for available liquidity).
contract ATokenMock {
    string public constant name = "aMOCK";
    address public immutable pool;
    address public immutable underlying;

    mapping(address => uint256) public balanceOf;

    constructor(address _pool, address _underlying) {
        pool = _pool;
        underlying = _underlying;
    }

    modifier onlyPool() {
        require(msg.sender == pool, "ATokenMock: only pool");
        _;
    }

    function mint(address to, uint256 amount) external onlyPool {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external onlyPool {
        balanceOf[from] -= amount;
    }

    /// @dev Pool moves underlying out of this market on withdrawal.
    function transferUnderlying(address to, uint256 amount) external onlyPool {
        ERC20Mock(underlying).transfer(to, amount);
    }

    /// @dev Test-only: simulate interest accrual (rebasing). Keeps the market backed so the grown
    /// balance remains withdrawable.
    function accrue(address account, uint256 amount) external {
        balanceOf[account] += amount;
        ERC20Mock(underlying).mint(address(this), amount);
    }
}

/// @notice Minimal Aave V2 LendingPool. Deposits route underlying into the aToken contract and mint
/// aTokens; withdrawals burn aTokens and return underlying. `withdrawShortfall` lets tests force the
/// "withdrew less than requested" path that AquaStrategy guards against.
contract AaveLendingPoolMock {
    address public immutable underlying;
    ATokenMock public aToken;
    uint256 public withdrawShortfall; // amount to under-deliver on the next withdraw

    constructor(address _underlying) {
        underlying = _underlying;
    }

    function setAToken(address _aToken) external {
        aToken = ATokenMock(_aToken);
    }

    function setWithdrawShortfall(uint256 shortfall) external {
        withdrawShortfall = shortfall;
    }

    function deposit(address asset_, uint256 amount, address onBehalfOf, uint16) external {
        require(asset_ == underlying, "wrong asset");
        ERC20Mock(underlying).transferFrom(msg.sender, address(aToken), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset_, uint256 amount, address to) external returns (uint256) {
        require(asset_ == underlying, "wrong asset");
        uint256 delivered = amount - withdrawShortfall;
        aToken.burn(msg.sender, delivered);
        aToken.transferUnderlying(to, delivered);
        return delivered;
    }
}
