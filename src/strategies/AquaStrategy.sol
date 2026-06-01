// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IAaveV2, IAaveV2AToken} from "./interfaces/IAaveV2.sol";
import {AccessManaged} from "../AccessManaged.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

/// @notice Aave V2 supply strategy. Allocate routes underlying to the lending pool, deallocate withdraws
/// it back. `totalAssets()` reads the aToken balance which rebases with Aave's accrued interest.
///
/// SAFETY (mirrors MorphoStrategy's emergency surface)
/// @dev `writeOff` lets GOVERNANCE subtract a phantom amount from `totalAssets()`. Use when the Aave pool
/// is broken/paused and the aToken balance is no longer realizable — prevents the vault NAV from counting
/// assets we can't actually withdraw. Mirrors MorphoStrategy.burnShares.
/// @dev `skim` lets `skimRecipient` recover reward tokens (stkAAVE) or mistakenly-sent tokens; the
/// underlying asset and aToken itself are protected (they back vault NAV).
contract AquaStrategy is IStrategy, AccessManaged {
    /* IMMUTABLES */

    address public immutable vault;
    address public immutable asset;
    address public immutable lendingPool;
    address public immutable aToken;
    /// @dev Stable, vault-wide identifier for this strategy instance. Used as `ids[0]` so the vault can
    /// enforce an aggregate cap across this strategy.
    bytes32 public immutable adapterId;

    /* STORAGE */

    /// @dev Destination for non-underlying token sweeps (rewards, donations, mis-sent tokens).
    address public skimRecipient;
    /// @dev Amount subtracted from `totalAssets()` when reporting NAV. Monotonically increases via
    /// `writeOff` — irreversible by design so an emergency call cannot be silently undone.
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
    }

    /* GOVERNANCE FUNCTIONS */

    function setSkimRecipient(address newSkimRecipient) external onlyRole(GOVERNANCE_ROLE) {
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @notice Emergency: increase the amount this strategy reports as un-realizable. Subtracts from
    /// `totalAssets()` immediately so the vault NAV stops counting unwithdrawable balance.
    /// @dev Monotonic — only increases. If governance later wants to "undo", they need a new vote to
    /// e.g. redeploy a fresh strategy; we deliberately don't expose a decrease path so a single rogue
    /// call cannot wipe the write-off.
    function writeOff(uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        uint256 reported = IAaveV2AToken(aToken).balanceOf(address(this));
        uint256 newTotal = writtenOff + amount;
        require(newTotal <= reported, WriteOffExceedsBalance());
        writtenOff = newTotal;
        emit WriteOff(amount, newTotal);
    }

    /* SKIM */

    /// @notice Sweep an arbitrary token balance to `skimRecipient`. Useful for Aave reward tokens
    /// (stkAAVE, etc.) or mistakenly-sent assets. The underlying and aToken are protected.
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

    function allocate(bytes memory, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory ids, int256 change)
    {
        if (assets > 0) IAaveV2(lendingPool).deposit(asset, assets, address(this), 0);
        ids = _ids();
        change = int256(assets);
    }

    function deallocate(bytes memory, uint256 assets, bytes4, address)
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

    /// @dev Two-level id namespacing so the vault can apply caps at:
    ///   ids[0] = this strategy as a whole (per-instance cap)
    ///   ids[1] = the underlying aToken (groups all Aqua strategies pointing at the same aToken)
    function _ids() internal view returns (bytes32[] memory ids_) {
        ids_ = new bytes32[](2);
        ids_[0] = adapterId;
        ids_[1] = keccak256(abi.encode("aToken", aToken));
    }
}
