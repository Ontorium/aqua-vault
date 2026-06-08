// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IAaveV2, IAaveV2AToken} from "./interfaces/IAaveV2.sol";
import {AccessManaged} from "../AccessManaged.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

/// @notice Aave V2 supply strategy.
/// @dev `totalAssets()` tracks the strategy's aToken balance, net of any write-off.
contract AquaStrategy is IStrategy, AccessManaged {
    /* IMMUTABLES */

    address public immutable vault;
    address public immutable asset;
    address public immutable lendingPool;
    address public immutable aToken;
    /// @dev Strategy-level id used for aggregate caps.
    bytes32 public immutable adapterId;

    /* STORAGE */

    /// @dev Recipient for non-underlying token sweeps.
    address public skimRecipient;
    /// @dev Amount excluded from `totalAssets()`.
    uint256 public writtenOff;

    /* ERRORS */

    error CannotSkimUnderlying();
    error CannotSkimAToken();
    error SkimRecipientUnset();
    error WriteOffExceedsBalance();

    /* EVENTS */

    event Skim(address indexed token, uint256 amount);
    event SetSkimRecipient(address indexed recipient);
    event WriteOff(uint256 amount, uint256 totalWrittenOff);

    modifier onlyVault() {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        _;
    }

    constructor(address _vault, address _asset, address _lendingPool, address _aToken, address _roleManager)
        AccessManaged(_roleManager, _vault)
    {
        require(_asset != address(0), ErrorsLib.ZeroAddress());
        require(_lendingPool != address(0), ErrorsLib.ZeroAddress());
        require(_aToken != address(0), ErrorsLib.ZeroAddress());

        vault = _vault;
        asset = _asset;
        lendingPool = _lendingPool;
        aToken = _aToken;
        adapterId = keccak256(abi.encode("AquaStrategy", address(this)));

        SafeERC20Lib.safeApprove(_asset, _lendingPool, type(uint256).max);
        // Vault pulls deallocated funds via transferFrom(strategy, vault, amt).
        SafeERC20Lib.safeApprove(_asset, _vault, type(uint256).max);
    }

    /* GOVERNANCE FUNCTIONS */

    function setSkimRecipient(address newSkimRecipient) external onlyRole(GOVERNANCE_ROLE) {
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @notice Increases the amount excluded from reported assets.
    /// @dev The write-off is monotonic.
    function writeOff(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        uint256 reported = IAaveV2AToken(aToken).balanceOf(address(this));
        uint256 newTotal = writtenOff + amount;
        require(newTotal <= reported, WriteOffExceedsBalance());
        writtenOff = newTotal;
        emit WriteOff(amount, newTotal);
    }

    /* SKIM */

    /// @notice Sweeps a non-underlying token balance to `skimRecipient`.
    function skim(address token) external {
        address recipient = skimRecipient;
        require(recipient != address(0), SkimRecipientUnset());
        require(msg.sender == recipient, ErrorsLib.Unauthorized());
        require(token != asset, CannotSkimUnderlying());
        require(token != aToken, CannotSkimAToken());

        uint256 balance = IERC20(token).balanceOf(address(this));
        SafeERC20Lib.safeTransfer(token, recipient, balance);
        emit Skim(token, balance);
    }

    /* ALLOCATE / DEALLOCATE */

    function allocate(bytes calldata, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        if (assets > 0) IAaveV2(lendingPool).deposit(asset, assets, address(this), 0);
        ids = _ids();
        change = int256(assets);
    }

    function deallocate(bytes calldata, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        if (assets > 0) {
            uint256 withdrawn = IAaveV2(lendingPool).withdraw(asset, assets, address(this));
            require(withdrawn == assets, ErrorsLib.InsufficientLiquidity());
        }
        ids = _ids();
        change = -int256(assets);
    }

    /* VIEWS */

    function realAssets() external view returns (uint256) {
        return totalAssets();
    }

    function totalAssets() public view returns (uint256) {
        uint256 raw = IAaveV2AToken(aToken).balanceOf(address(this));
        uint256 wo = writtenOff;
        return raw > wo ? raw - wo : 0;
    }

    function availableLiquidity() external view returns (uint256) {
        uint256 total = totalAssets();
        uint256 poolLiquidity = IERC20(asset).balanceOf(aToken);
        return poolLiquidity < total ? poolLiquidity : total;
    }

    /// @dev Returns ids for strategy- and aToken-level caps.
    function _ids() internal view returns (bytes32[] memory ids_) {
        ids_ = new bytes32[](2);
        ids_[0] = adapterId;
        ids_[1] = keccak256(abi.encode("aToken", aToken));
    }
}
