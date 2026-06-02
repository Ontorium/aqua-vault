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

/// @notice Morpho Blue supply strategy for whitelisted markets.
/// @dev Governance can write off a market with `burnShares` if reporting becomes unsafe.
contract MorphoStrategy is IStrategy, AccessManaged {
    using MorphoBalancesLib for IMorpho;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    /* IMMUTABLES */

    address public immutable vault;
    address public immutable asset;
    IMorpho public immutable morpho;
    /// @dev Strategy-level id used for aggregate caps.
    bytes32 public immutable adapterId;

    /* STORAGE */

    Id[] internal _marketIds;
    mapping(Id marketId => uint256) internal _marketIndexPlusOne;
    /// @dev Cached market params for view paths.
    mapping(Id marketId => MarketParams) internal _marketParams;
    /// @dev Locally tracked supply shares per market.
    mapping(Id marketId => uint256) public supplyShares;
    /// @dev Allowlist of IRM contracts.
    mapping(address irm => bool) public irmApproved;
    /// @dev Recipient for non-underlying token sweeps.
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

    /// @dev Returns the projected supply assets for `marketId`.
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

    /// @notice Writes off a market by zeroing its tracked shares.
    /// @dev The underlying Morpho position remains untouched.
    function burnShares(Id marketId) external onlyRole(GOVERNANCE_ROLE) {
        uint256 sharesBefore = supplyShares[marketId];
        if (sharesBefore == 0) return;
        supplyShares[marketId] = 0;
        _syncMarketList(marketId, sharesBefore, 0);
        emit BurnShares(marketId, sharesBefore);
    }

    /* SKIM */

    /// @notice Sweeps a non-underlying token balance to `skimRecipient`.
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
            // Cache market params for subsequent view calls.
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
        // Do not block exits if a market later becomes unapproved.

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
            unchecked {
                ++i;
            }
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
            unchecked {
                ++i;
            }
        }
    }

    /* INTERNAL HELPERS */

    /// @dev Projects supply assets from locally tracked shares.
    function _expectedSupplyAssets(Id marketId, MarketParams memory mp) internal view returns (uint256) {
        uint256 shares = supplyShares[marketId];
        if (shares == 0) return 0;
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) = morpho.expectedMarketBalances(mp);
        return shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    /// @dev Returns ids for strategy-, collateral-, and market-level caps.
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
            // Keep cached params so a later re-entry can reuse them.
        }
    }
}
