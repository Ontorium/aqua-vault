// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
// Morpho Blue periphery is vendored under ./morpho to avoid an external git submodule.
import {IMorpho, MarketParams, Id} from "./morpho/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "./morpho/libraries/periphery/MorphoBalancesLib.sol";
import {MarketParamsLib} from "./morpho/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "./morpho/libraries/SharesMathLib.sol";
import {AccessManaged} from "../AccessManaged.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

/// @notice Morpho Blue supply strategy, modeled after Morpho's `MorphoMarketV1AdapterV2` but adapted to
/// the aqua-vault role/scope model. Supplies vault underlying to whitelisted Morpho markets and reports
/// the accrued position as `totalAssets()`.
///
/// SAFETY
/// @dev Markets must use an IRM whitelisted by GOVERNANCE (`setIrmApproved`). Allocations are rejected
/// otherwise; deallocations are not restricted so the vault can always exit a market whose IRM is later
/// revoked.
/// @dev If a market's IRM/oracle breaks (`expectedSupplyAssets` reverts), `totalAssets()` reverts and the
/// vault cannot accrue interest. GOVERNANCE can call `burnShares(marketId)` to write the position off and
/// remove it from the active list — the actual shares stay on Morpho but stop polluting the vault NAV.
/// @dev `mintedShares >= assets` is required on supply, a defense-in-depth check against share-price
/// inflation in newly-created markets. Morpho Blue requires an initial supply but this is a second guard.
contract MorphoStrategy is IStrategy, AccessManaged {
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /* IMMUTABLES */

    address public immutable vault;
    address public immutable asset;
    IMorpho public immutable morpho;
    /// @dev Stable, vault-wide identifier for this strategy instance. Used as `ids[0]` so the vault can
    /// enforce an aggregate cap across all of this strategy's markets.
    bytes32 public immutable adapterId;

    /* STORAGE */

    Id[] internal _marketIds;
    mapping(Id marketId => uint256) internal _marketIndexPlusOne;
    /// @dev Stored `MarketParams` per registered market. Required for view paths (no `data` arg).
    mapping(Id marketId => MarketParams) internal _marketParams;
    /// @dev Locally tracked supply shares per market. The single source of truth for `totalAssets()`,
    /// so `burnShares` can write off a market without touching Morpho's storage.
    mapping(Id marketId => uint256) public supplyShares;
    /// @dev Allowlist of IRM contracts that markets may use. GOVERNANCE manages this set.
    mapping(address irm => bool) public irmApproved;
    /// @dev Destination for non-underlying token sweeps (rewards, donations, mis-sent tokens).
    address public skimRecipient;

    /* ERRORS */

    error LoanAssetMismatch();
    error IrmNotApproved();
    error SharePriceAboveOne();
    error CannotSkimUnderlying();
    error SkimRecipientUnset();

    /* EVENTS */

    event BurnShares(Id indexed marketId, uint256 sharesBefore);
    event Skim(address indexed token, uint256 amount);
    event SetSkimRecipient(address indexed recipient);
    event SetIrmApproved(address indexed irm, bool approved);

    modifier onlyVault() {
        require(msg.sender == vault, ErrorsLib.Unauthorized());
        _;
    }

    constructor(address _vault, address _asset, address _morpho, address _roleManager)
        AccessManaged(_roleManager, _vault)
    {
        require(_asset != address(0), ErrorsLib.ZeroAddress());
        require(_morpho != address(0), ErrorsLib.ZeroAddress());

        vault = _vault;
        asset = _asset;
        morpho = IMorpho(_morpho);
        adapterId = keccak256(abi.encode("MorphoStrategy", address(this)));

        SafeERC20Lib.safeApprove(_asset, _morpho, type(uint256).max);
    }

    /* GETTERS */

    function marketIdsLength() external view returns (uint256) {
        return _marketIds.length;
    }

    function marketIds(uint256 index) external view returns (Id) {
        return _marketIds[index];
    }

    function marketParams(Id marketId) external view returns (MarketParams memory) {
        return _marketParams[marketId];
    }

    /// @dev Returns this strategy's projected supply assets on a market (interest-accrued, view-only).
    function expectedSupplyAssets(Id marketId) external view returns (uint256) {
        return _expectedSupplyAssets(marketId, _marketParams[marketId]);
    }

    /* GOVERNANCE FUNCTIONS */

    function setIrmApproved(address irm, bool approved) external onlyRole(GOVERNANCE_ROLE) {
        require(irm != address(0), ErrorsLib.ZeroAddress());
        irmApproved[irm] = approved;
        emit SetIrmApproved(irm, approved);
    }

    function setSkimRecipient(address newSkimRecipient) external onlyRole(GOVERNANCE_ROLE) {
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @notice Emergency: zero out this strategy's tracked shares on a market. `totalAssets()` immediately
    /// stops counting the position and the market is removed from the active list.
    /// @dev The actual shares remain on Morpho (lost forever). Use when an IRM/oracle is broken or a market
    /// is otherwise compromised and reporting an inflated NAV.
    function burnShares(Id marketId) external onlyRole(GOVERNANCE_ROLE) {
        uint256 sharesBefore = supplyShares[marketId];
        if (sharesBefore == 0) return;
        supplyShares[marketId] = 0;
        _syncMarketList(marketId, sharesBefore, 0);
        emit BurnShares(marketId, sharesBefore);
    }

    /* SKIM */

    /// @notice Sweep an arbitrary token balance to `skimRecipient`. Useful for Morpho reward tokens
    /// or mistakenly-sent assets. Cannot skim the strategy's underlying asset (that backs vault NAV).
    function skim(address token) external {
        address recipient = skimRecipient;
        require(recipient != address(0), SkimRecipientUnset());
        require(msg.sender == recipient, ErrorsLib.Unauthorized());
        require(token != asset, CannotSkimUnderlying());

        uint256 balance = IERC20(token).balanceOf(address(this));
        SafeERC20Lib.safeTransfer(token, recipient, balance);
        emit Skim(token, balance);
    }

    /* ALLOCATE / DEALLOCATE */

    function allocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory, int256 change)
    {
        MarketParams memory mp = abi.decode(data, (MarketParams));
        require(mp.loanToken == asset, LoanAssetMismatch());
        require(irmApproved[mp.irm], IrmNotApproved());

        Id marketId = mp.id();
        uint256 oldAssets = _expectedSupplyAssets(marketId, mp);

        if (assets > 0) {
            (, uint256 mintedShares) = morpho.supply(mp, assets, 0, address(this), hex"");
            require(mintedShares >= assets, SharePriceAboveOne());
            supplyShares[marketId] += mintedShares;
            // First time we see this market: snapshot its params so views can query MorphoBalancesLib.
            if (_marketParams[marketId].loanToken == address(0)) _marketParams[marketId] = mp;
        }

        uint256 newAssets = _expectedSupplyAssets(marketId, mp);
        _syncMarketList(marketId, oldAssets, newAssets);

        change = int256(newAssets) - int256(oldAssets);
        return (_ids(mp), change);
    }

    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        onlyVault
        returns (bytes32[] memory, int256 change)
    {
        MarketParams memory mp = abi.decode(data, (MarketParams));
        require(mp.loanToken == asset, LoanAssetMismatch());
        // Intentionally NO `irmApproved` check — we want to always be able to exit a market whose IRM
        // was later un-approved or is otherwise broken.

        Id marketId = mp.id();
        uint256 oldAssets = _expectedSupplyAssets(marketId, mp);

        if (assets > 0) {
            (, uint256 burnedShares) = morpho.withdraw(mp, assets, 0, address(this), address(this));
            supplyShares[marketId] -= burnedShares;
        }

        uint256 newAssets = _expectedSupplyAssets(marketId, mp);
        _syncMarketList(marketId, oldAssets, newAssets);

        change = int256(newAssets) - int256(oldAssets);
        return (_ids(mp), change);
    }

    /* AGGREGATE VIEWS */

    function realAssets() external view returns (uint256) {
        return totalAssets();
    }

    function totalAssets() public view returns (uint256 total) {
        uint256 len = _marketIds.length;
        for (uint256 i; i < len;) {
            Id marketId = _marketIds[i];
            total += _expectedSupplyAssets(marketId, _marketParams[marketId]);
            unchecked { ++i; }
        }
    }

    function availableLiquidity() external view returns (uint256 liquidity) {
        uint256 len = _marketIds.length;
        for (uint256 i; i < len;) {
            Id marketId = _marketIds[i];
            MarketParams memory mp = _marketParams[marketId];
            (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = morpho.expectedMarketBalances(mp);

            uint256 onMarket = _expectedSupplyAssets(marketId, mp);
            uint256 free = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
            liquidity += free < onMarket ? free : onMarket;
            unchecked { ++i; }
        }
    }

    /* INTERNAL HELPERS */

    /// @dev Projects this strategy's supply assets on a market from our locally tracked shares, using
    /// MorphoBalancesLib's interest-accrued totals. Returns 0 short-circuit if we have no shares (so a
    /// market burned via `burnShares` contributes 0 even if it's still in the list).
    function _expectedSupplyAssets(Id marketId, MarketParams memory mp) internal view returns (uint256) {
        uint256 shares = supplyShares[marketId];
        if (shares == 0) return 0;
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) = morpho.expectedMarketBalances(mp);
        return shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    /// @dev Multi-level id namespacing so the vault can apply caps at three granularities:
    ///   ids[0] = this strategy as a whole (every market goes through it)
    ///   ids[1] = the collateral token used by the market (groups all markets sharing it)
    ///   ids[2] = the specific market
    function _ids(MarketParams memory mp) internal view returns (bytes32[] memory ids_) {
        ids_ = new bytes32[](3);
        ids_[0] = adapterId;
        ids_[1] = keccak256(abi.encode("collateralToken", mp.collateralToken));
        ids_[2] = keccak256(abi.encode(address(this), Id.unwrap(mp.id())));
    }

    function _syncMarketList(Id marketId, uint256 oldAssets, uint256 newAssets) internal {
        uint256 indexPlusOne = _marketIndexPlusOne[marketId];
        if (oldAssets == 0 && newAssets > 0 && indexPlusOne == 0) {
            _marketIds.push(marketId);
            _marketIndexPlusOne[marketId] = _marketIds.length;
            return;
        }

        if (oldAssets > 0 && newAssets == 0 && indexPlusOne != 0) {
            uint256 index = indexPlusOne - 1;
            uint256 lastIndex = _marketIds.length - 1;

            if (index != lastIndex) {
                Id lastMarketId = _marketIds[lastIndex];
                _marketIds[index] = lastMarketId;
                _marketIndexPlusOne[lastMarketId] = index + 1;
            }

            _marketIds.pop();
            delete _marketIndexPlusOne[marketId];
            // Keep `_marketParams[marketId]` so a re-entry can reuse the snapshot; cheap & harmless.
        }
    }
}
