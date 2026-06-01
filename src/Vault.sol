// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IVault, PendingWithdrawal} from "./interfaces/IVault.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IStrategyManager} from "./interfaces/IStrategyManager.sol";
import {AccessManaged} from "./AccessManaged.sol";
import {RoleManager} from "./RoleManager.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import "./libraries/ConstantsLib.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {SafeERC20Lib} from "./libraries/SafeERC20Lib.sol";
import {IReceiveSharesGate, ISendSharesGate, IReceiveAssetsGate, ISendAssetsGate} from "./interfaces/IGate.sol";

contract Vault is IVault, AccessManaged {
    using MathLib for uint256;
    using MathLib for uint128;
    using MathLib for int256;

    /* IMMUTABLE */

    address public immutable asset;
    uint8 public immutable decimals;
    uint256 public immutable virtualShares;

    /* WIRING STORAGE */

    address public receiveSharesGate;
    address public sendSharesGate;
    address public receiveAssetsGate;
    address public sendAssetsGate;
    address public strategyManager;
    address public priceManager;

    /* TOKEN STORAGE */

    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;
    mapping(address account => uint256) public nonces;

    /* INTEREST STORAGE */

    uint256 public transient firstTotalAssets;
    uint128 public _totalAssets;
    uint64 public lastUpdate;
    uint64 public maxRate;

    /* STRATEGY STORAGE */

    /// @dev Strategy registry/caps/allocation live in StrategyManager.
    /// @dev Vault keeps custody of assets and only asks StrategyManager to validate/update accounting.

    /* FEES STORAGE */

    uint96 public performanceFee;
    address public performanceFeeRecipient;
    uint96 public managementFee;
    address public managementFeeRecipient;
    /// @dev Charged on deposit/mint (WAD-scaled, e.g. 1e16 = 1%). Routed to protocolFeeRecipient.
    uint96 public depositFee;
    /// @dev Charged on withdraw/redeem (WAD-scaled). Routed to protocolFeeRecipient.
    uint96 public withdrawalFee;
    /// @dev Treasury for principal-side fees (deposit/withdrawal). Set/changed via TREASURY-style governance.
    address public protocolFeeRecipient;

    /* WITHDRAWAL QUEUE STORAGE */

    /// @dev Per-user accumulating queue (Centrifuge-style). All queued requests by the same
    /// `onBehalf` collapse into one storage slot — first request pays the cold-SSTORE cost
    /// (~20k gas), subsequent ones pay only ~5k (slot update). `delete` on claim/cancel reclaims
    /// the slot for a gas refund.
    mapping(address onBehalf => PendingWithdrawal) public pendingWithdrawal;
    /// @dev Operator-fulfilled, per-user claim right (ERC-7540 / Centrifuge `maxWithdraw` style). Only the
    /// ALLOCATOR can move a request from `pendingWithdrawal` into here via {fulfillWithdrawal}; once here the
    /// liquidity is reserved for `onBehalf` and cannot be taken by anyone else.
    mapping(address onBehalf => uint128) public claimableAssets;
    /// @dev Locked withdrawalFee (WAD-scaled) snapshot moved here from `pendingWithdrawal.feeAtRequest`
    /// at fulfillment time, so {claim} uses the fee policy in effect when the request was queued — NOT the
    /// `withdrawalFee` at claim time. If a user has unclaimed assets and a new fulfillment merges in, the
    /// stored fee is a weighted average by assets so each batch contributes its own fee fairly.
    mapping(address onBehalf => uint64) public claimableFee;
    /// @dev Sum of `claimableAssets` across all users — the locked pool backing fulfilled claims. Invariant:
    /// `asset.balanceOf(vault) >= reservedAssets` (maintained by {fulfillWithdrawal} and the allocate guard).
    uint256 public reservedAssets;
    /// @dev Total assets owed to exiting users = Σ pending request assets + `reservedAssets`. Subtracted from
    /// idle balance when computing liquidity available for immediate withdrawals; unchanged by fulfillment
    /// (which just moves an amount from the pending sub-total into `reservedAssets`).
    uint256 public pendingClaimableAssets;

    /* PAUSE STORAGE */

    /// @dev When true, new inflows and strategy allocations are blocked. Withdrawals (withdraw/redeem/
    /// claim/forceDeallocate) remain open so users can always exit. SENTINEL pauses, GOVERNANCE unpauses.
    bool public paused;

    modifier whenNotPaused() {
        require(!paused, ErrorsLib.Paused());
        _;
    }

    /* GETTERS */

    /// @dev Strategy registry, caps, allocation, per-strategy/per-id queries and aggregate liquidity views
    /// are intentionally NOT mirrored here — query StrategyManager (via strategyManager()) directly.

    function totalAssets() external view returns (uint256) {
        (uint256 newTotalAssets,,) = accrueInterestView();
        return newTotalAssets;
    }

    /// forge-lint: disable-next-item(mixed-case-function)
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    /* MULTICALL */

    /// @dev Useful for EOAs to batch admin calls.
    /// @dev Does not return anything, because accounts who would use the return data would be contracts, which can do
    /// the multicall themselves.
    function multicall(bytes[] calldata data) external {
        uint256 len = data.length;
        for (uint256 i; i < len;) {
            (bool success, bytes memory returnData) = address(this).delegatecall(data[i]);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(32, returnData), mload(returnData))
                }
            }
            unchecked { ++i; }
        }
    }

    /* CONSTRUCTOR */

    constructor(address _roleManager, address _asset) AccessManaged(_roleManager, address(this)) {
        asset = _asset;
        lastUpdate = uint64(block.timestamp);
        uint256 assetDecimals = IERC20(_asset).decimals();
        uint256 decimalOffset = uint256(18).zeroFloorSub(assetDecimals);
        // forge-lint: disable-next-item(unsafe-typecast) safe because assetDecimals + decimalOffset <= 18.
        decimals = uint8(assetDecimals + decimalOffset);
        virtualShares = 10 ** decimalOffset;
        emit EventsLib.Constructor(_roleManager, _asset);
    }

    /* GOVERNANCE FUNCTIONS (gated by RoleManager) */

    function setName(string memory newName) external onlyRole(GOVERNANCE_ROLE) {
        name = newName;
        emit EventsLib.SetName(newName);
    }

    function setSymbol(string memory newSymbol) external onlyRole(GOVERNANCE_ROLE) {
        symbol = newSymbol;
        emit EventsLib.SetSymbol(newSymbol);
    }

    function setReceiveSharesGate(address newReceiveSharesGate) external onlyRole(GOVERNANCE_ROLE) {
        receiveSharesGate = newReceiveSharesGate;
        emit EventsLib.SetReceiveSharesGate(newReceiveSharesGate);
    }

    function setSendSharesGate(address newSendSharesGate) external onlyRole(GOVERNANCE_ROLE) {
        sendSharesGate = newSendSharesGate;
        emit EventsLib.SetSendSharesGate(newSendSharesGate);
    }

    function setReceiveAssetsGate(address newReceiveAssetsGate) external onlyRole(GOVERNANCE_ROLE) {
        receiveAssetsGate = newReceiveAssetsGate;
        emit EventsLib.SetReceiveAssetsGate(newReceiveAssetsGate);
    }

    function setSendAssetsGate(address newSendAssetsGate) external onlyRole(GOVERNANCE_ROLE) {
        sendAssetsGate = newSendAssetsGate;
        emit EventsLib.SetSendAssetsGate(newSendAssetsGate);
    }

    /// @dev One-time setup so the factory can atomically deploy and link a dedicated StrategyManager.
    /// @dev The manager must explicitly point back to this Vault and use the same asset.
    function setStrategyManager(address newStrategyManager) external onlyRole(GOVERNANCE_ROLE) {
        require(strategyManager == address(0), ErrorsLib.InvalidStrategyManager());
        require(newStrategyManager != address(0), ErrorsLib.ZeroAddress());
        require(newStrategyManager.code.length != 0, ErrorsLib.NoCode());
        require(IStrategyManager(newStrategyManager).vault() == address(this), ErrorsLib.InvalidStrategyManager());
        require(IStrategyManager(newStrategyManager).asset() == asset, ErrorsLib.InvalidStrategyManager());

        strategyManager = newStrategyManager;
        emit EventsLib.SetStrategyManager(newStrategyManager);
    }

    function setPriceManager(address newPriceManager) external onlyRole(GOVERNANCE_ROLE) {
        require(newPriceManager != address(0), ErrorsLib.ZeroAddress());
        require(newPriceManager.code.length != 0, ErrorsLib.NoCode());
        priceManager = newPriceManager;
        emit EventsLib.SetPriceManager(newPriceManager);
    }

    function setPerformanceFee(uint256 newPerformanceFee) external onlyRole(GOVERNANCE_ROLE) {
        require(newPerformanceFee <= MAX_PERFORMANCE_FEE, ErrorsLib.FeeTooHigh());
        require(performanceFeeRecipient != address(0) || newPerformanceFee == 0, ErrorsLib.FeeInvariantBroken());

        accrueInterest();

        // forge-lint: disable-next-item(unsafe-typecast) safe because 2**96 > MAX_PERFORMANCE_FEE.
        performanceFee = uint96(newPerformanceFee);
        emit EventsLib.SetPerformanceFee(newPerformanceFee);
    }

    function setManagementFee(uint256 newManagementFee) external onlyRole(GOVERNANCE_ROLE) {
        require(newManagementFee <= MAX_MANAGEMENT_FEE, ErrorsLib.FeeTooHigh());
        require(managementFeeRecipient != address(0) || newManagementFee == 0, ErrorsLib.FeeInvariantBroken());

        accrueInterest();

        // forge-lint: disable-next-item(unsafe-typecast) safe because 2**96 > MAX_MANAGEMENT_FEE.
        managementFee = uint96(newManagementFee);
        emit EventsLib.SetManagementFee(newManagementFee);
    }

    function setPerformanceFeeRecipient(address newPerformanceFeeRecipient) external onlyRole(GOVERNANCE_ROLE) {
        require(newPerformanceFeeRecipient != address(0) || performanceFee == 0, ErrorsLib.FeeInvariantBroken());

        accrueInterest();

        performanceFeeRecipient = newPerformanceFeeRecipient;
        emit EventsLib.SetPerformanceFeeRecipient(newPerformanceFeeRecipient);
    }

    /* PAUSE CONTROLS */

    /// @notice Emergency-pause new inflows and allocations. Withdrawals stay open.
    /// @dev SENTINEL can pause for fast response; GOVERNANCE must unpause to confirm safety.
    function pause() external onlyRole(SENTINEL_ROLE) {
        paused = true;
        emit EventsLib.Paused(msg.sender);
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        paused = false;
        emit EventsLib.Unpaused(msg.sender);
    }

    function setDepositFee(uint256 newDepositFee) external onlyRole(GOVERNANCE_ROLE) {
        require(newDepositFee <= MAX_DEPOSIT_FEE, ErrorsLib.FeeTooHigh());
        require(protocolFeeRecipient != address(0) || newDepositFee == 0, ErrorsLib.FeeInvariantBroken());

        // forge-lint: disable-next-item(unsafe-typecast) safe because 2**96 > MAX_DEPOSIT_FEE.
        depositFee = uint96(newDepositFee);
        emit EventsLib.SetDepositFee(newDepositFee);
    }

    function setWithdrawalFee(uint256 newWithdrawalFee) external onlyRole(GOVERNANCE_ROLE) {
        require(newWithdrawalFee <= MAX_WITHDRAWAL_FEE, ErrorsLib.FeeTooHigh());
        require(protocolFeeRecipient != address(0) || newWithdrawalFee == 0, ErrorsLib.FeeInvariantBroken());

        // forge-lint: disable-next-item(unsafe-typecast) safe because 2**96 > MAX_WITHDRAWAL_FEE.
        withdrawalFee = uint96(newWithdrawalFee);
        emit EventsLib.SetWithdrawalFee(newWithdrawalFee);
    }

    function setProtocolFeeRecipient(address newProtocolFeeRecipient) external onlyRole(GOVERNANCE_ROLE) {
        require(
            newProtocolFeeRecipient != address(0) || (depositFee == 0 && withdrawalFee == 0),
            ErrorsLib.FeeInvariantBroken()
        );
        protocolFeeRecipient = newProtocolFeeRecipient;
        emit EventsLib.SetProtocolFeeRecipient(newProtocolFeeRecipient);
    }

    function setManagementFeeRecipient(address newManagementFeeRecipient) external onlyRole(GOVERNANCE_ROLE) {
        require(newManagementFeeRecipient != address(0) || managementFee == 0, ErrorsLib.FeeInvariantBroken());

        accrueInterest();

        managementFeeRecipient = newManagementFeeRecipient;
        emit EventsLib.SetManagementFeeRecipient(newManagementFeeRecipient);
    }

    /* ALLOCATOR FUNCTIONS */

    function allocate(address strategy, bytes memory data, uint256 assets)
        external
        whenNotPaused
        onlyRole(ALLOCATOR_ROLE)
    {
        allocateInternal(strategy, data, assets);
    }

    function allocateInternal(address strategy, bytes memory data, uint256 assets) internal {
        address _strategyManager = strategyManager;
        require(_strategyManager != address(0), ErrorsLib.ZeroAddress());

        accrueInterest();

        // Cannot push liquidity reserved for fulfilled withdrawals into a strategy.
        require(assets <= IERC20(asset).balanceOf(address(this)) - reservedAssets, ErrorsLib.InsufficientLiquidity());

        SafeERC20Lib.safeTransfer(asset, strategy, assets);
        (bytes32[] memory ids, int256 change) = IStrategy(strategy).allocate(data, assets, msg.sig, msg.sender);

        IStrategyManager(_strategyManager).onAllocate(strategy, ids, change, firstTotalAssets);

        emit EventsLib.Allocate(msg.sender, strategy, assets, ids, change);
    }

    function deallocate(address strategy, bytes memory data, uint256 assets) external {
        _requireAnyRole(ALLOCATOR_ROLE, SENTINEL_ROLE);
        deallocateInternal(strategy, data, assets);
    }

    function deallocateInternal(address strategy, bytes memory data, uint256 assets)
        internal
        returns (bytes32[] memory ids)
    {
        address _strategyManager = strategyManager;
        require(_strategyManager != address(0), ErrorsLib.ZeroAddress());

        int256 change;
        (ids, change) = IStrategy(strategy).deallocate(data, assets, msg.sig, msg.sender);

        IStrategyManager(_strategyManager).onDeallocate(strategy, ids, change);

        SafeERC20Lib.safeTransferFrom(asset, strategy, address(this), assets);
        emit EventsLib.Deallocate(msg.sender, strategy, assets, ids, change);
    }

    function setMaxRate(uint256 newMaxRate) external onlyRole(GOVERNANCE_ROLE) {
        require(newMaxRate <= MAX_MAX_RATE, ErrorsLib.MaxRateTooHigh());

        accrueInterest();

        // forge-lint: disable-next-item(unsafe-typecast) safe because newMaxRate <= MAX_MAX_RATE < 2**64-1.
        maxRate = uint64(newMaxRate);
        emit EventsLib.SetMaxRate(newMaxRate);
    }

    /* EXCHANGE RATE FUNCTIONS */

    function accrueInterest() public {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        _applyAccruedTotalAssets(newTotalAssets, performanceFeeShares, managementFeeShares);
    }

    /// @dev PriceManager-only NAV sync path that bypasses maxRate and immediately reflects reported offchain NAV.
    function syncReportedNAV() external {
        require(msg.sender == priceManager, ErrorsLib.Unauthorized());

        uint256 newTotalAssets = _realAssets();
        uint256 previousTotalAssets = _totalAssets;
        (uint256 performanceFeeShares, uint256 managementFeeShares) =
            _previewFeeShares(previousTotalAssets, newTotalAssets, block.timestamp - lastUpdate);

        _applyAccruedTotalAssets(newTotalAssets, performanceFeeShares, managementFeeShares);
        emit EventsLib.SyncReportedNAV(msg.sender, previousTotalAssets, newTotalAssets);
    }

    function _applyAccruedTotalAssets(
        uint256 newTotalAssets,
        uint256 performanceFeeShares,
        uint256 managementFeeShares
    ) internal {
        emit EventsLib.AccrueInterest(_totalAssets, newTotalAssets, performanceFeeShares, managementFeeShares);
        _totalAssets = newTotalAssets.toUint128();
        if (firstTotalAssets == 0) firstTotalAssets = newTotalAssets;
        if (performanceFeeShares != 0) createShares(performanceFeeRecipient, performanceFeeShares);
        if (managementFeeShares != 0) createShares(managementFeeRecipient, managementFeeShares);
        lastUpdate = uint64(block.timestamp);
    }

    /// @dev Returns newTotalAssets, performanceFeeShares, managementFeeShares.
    /// @dev The management fee is not bound to the interest, so it can make the share price go down.
    /// @dev The management fees is taken even if the vault incurs some losses.
    /// @dev Both fees are rounded down, so fee recipients could receive less than expected.
    /// @dev The performance fee is taken on the "distributed interest" (which differs from the "real interest" because
    /// of the max rate).
    function accrueInterestView() public view returns (uint256, uint256, uint256) {
        if (firstTotalAssets != 0) return (_totalAssets, 0, 0);
        uint256 elapsed = block.timestamp - lastUpdate;
        uint256 realAssets = _realAssets();
        uint256 maxTotalAssets = _totalAssets + (_totalAssets * elapsed).mulDivDown(maxRate, WAD);
        uint256 newTotalAssets = MathLib.min(realAssets, maxTotalAssets);
        (uint256 performanceFeeShares, uint256 managementFeeShares) =
            _previewFeeShares(_totalAssets, newTotalAssets, elapsed);
        return (newTotalAssets, performanceFeeShares, managementFeeShares);
    }

    function _previewFeeShares(uint256 previousTotalAssets, uint256 newTotalAssets, uint256 elapsed)
        internal
        view
        returns (uint256 performanceFeeShares, uint256 managementFeeShares)
    {
        uint256 interest = newTotalAssets.zeroFloorSub(previousTotalAssets);

        uint256 performanceFeeAssets = interest > 0 && performanceFee > 0 && canReceiveShares(performanceFeeRecipient)
            ? interest.mulDivDown(performanceFee, WAD)
            : 0;
        uint256 managementFeeAssets = elapsed > 0 && managementFee > 0 && canReceiveShares(managementFeeRecipient)
            ? (newTotalAssets * elapsed).mulDivDown(managementFee, WAD)
            : 0;

        uint256 newTotalAssetsWithoutFees = newTotalAssets - performanceFeeAssets - managementFeeAssets;
        performanceFeeShares =
            performanceFeeAssets.mulDivDown(totalSupply + virtualShares, newTotalAssetsWithoutFees + 1);
        managementFeeShares =
            managementFeeAssets.mulDivDown(totalSupply + virtualShares, newTotalAssetsWithoutFees + 1);
    }

    function _realAssets() internal view returns (uint256 realAssets) {
        realAssets = IERC20(asset).balanceOf(address(this)).zeroFloorSub(pendingClaimableAssets);
        if (strategyManager != address(0)) realAssets += IStrategyManager(strategyManager).totalStrategyAssets();
    }

    /// @dev Returns previewed minted shares (depositFee deducted from input assets).
    function previewDeposit(uint256 assets) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        uint256 netAssets = assets - assets.mulDivUp(depositFee, WAD);
        return netAssets.mulDivDown(newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @dev Returns previewed deposited assets (caller pays gross = netAssets + depositFee).
    function previewMint(uint256 shares) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        uint256 netAssets = shares.mulDivUp(newTotalAssets + 1, newTotalSupply + virtualShares);
        return depositFee == 0 ? netAssets : netAssets.mulDivUp(WAD, WAD - depositFee);
    }

    /// @dev Returns previewed redeemed shares (caller burns gross to receive net assets after withdrawalFee).
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        uint256 grossAssets = withdrawalFee == 0 ? assets : assets.mulDivUp(WAD, WAD - withdrawalFee);
        return grossAssets.mulDivUp(newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @dev Returns previewed withdrawn assets (receiver gets net after withdrawalFee).
    function previewRedeem(uint256 shares) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        uint256 grossAssets = shares.mulDivDown(newTotalAssets + 1, newTotalSupply + virtualShares);
        return grossAssets - grossAssets.mulDivUp(withdrawalFee, WAD);
    }

    /// @dev Returns corresponding shares (rounded down) at current price. Fee-agnostic per ERC-4626 spec.
    function convertToShares(uint256 assets) external view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        return assets.mulDivDown(newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @dev Returns corresponding assets (rounded down) at current price. Fee-agnostic per ERC-4626 spec.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        return shares.mulDivDown(newTotalAssets + 1, newTotalSupply + virtualShares);
    }

    /* MAX FUNCTIONS */

    /// @dev Gross underestimation because being revert-free cannot be guaranteed when calling the gate.
    function maxDeposit(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Gross underestimation because being revert-free cannot be guaranteed when calling the gate.
    function maxMint(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Gross underestimation because being revert-free cannot be guaranteed when calling the gate.
    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Gross underestimation because being revert-free cannot be guaranteed when calling the gate.
    function maxRedeem(address) external pure returns (uint256) {
        return 0;
    }

    /* USER MAIN FUNCTIONS */

    /// @dev Charges `depositFee` on the way in; returns shares minted for the net (post-fee) amount.
    function deposit(uint256 assets, address onBehalf) external whenNotPaused returns (uint256) {
        accrueInterest();
        uint256 shares = previewDeposit(assets);
        uint256 fee = assets.mulDivUp(depositFee, WAD);
        uint256 netAssets = assets - fee;
        _enter(assets, netAssets, fee, shares, onBehalf);
        return shares;
    }

    /// @dev Mints exactly `shares` to onBehalf. Caller pays grossAssets = netAssets + fee.
    function mint(uint256 shares, address onBehalf) external whenNotPaused returns (uint256) {
        accrueInterest();
        uint256 grossAssets = previewMint(shares);
        uint256 fee = grossAssets.mulDivUp(depositFee, WAD);
        uint256 netAssets = grossAssets - fee;
        _enter(grossAssets, netAssets, fee, shares, onBehalf);
        return grossAssets;
    }

    /// @dev Internal entry path. `assets` is what msg.sender pays in; `netAssets` is what backs new shares.
    function _enter(uint256 assets, uint256 netAssets, uint256 fee, uint256 shares, address onBehalf) internal {
        require(canReceiveShares(onBehalf), ErrorsLib.CannotReceiveShares());
        require(canSendAssets(msg.sender), ErrorsLib.CannotSendAssets());

        SafeERC20Lib.safeTransferFrom(asset, msg.sender, address(this), assets);
        if (fee > 0) {
            require(protocolFeeRecipient != address(0), ErrorsLib.FeeInvariantBroken());
            SafeERC20Lib.safeTransfer(asset, protocolFeeRecipient, fee);
        }
        createShares(onBehalf, shares);
        _totalAssets += netAssets.toUint128();
        emit EventsLib.Deposit(msg.sender, onBehalf, netAssets, shares);
    }

    /// @dev `assets` is what the receiver ends up with after withdrawalFee. Caller burns shares for grossAssets.
    function withdraw(uint256 assets, address receiver, address onBehalf) public returns (uint256) {
        accrueInterest();
        uint256 shares = previewWithdraw(assets);
        uint256 grossAssets =
            withdrawalFee == 0 ? assets : assets.mulDivUp(WAD, WAD - withdrawalFee);
        uint256 fee = grossAssets - assets;
        _exit(grossAssets, assets, fee, shares, receiver, onBehalf);
        return shares;
    }

    /// @dev Burns `shares` from onBehalf. Receiver gets netAssets after fee.
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256) {
        accrueInterest();
        uint256 netAssets = previewRedeem(shares);
        uint256 grossAssets =
            withdrawalFee == 0 ? netAssets : netAssets.mulDivUp(WAD, WAD - withdrawalFee);
        uint256 fee = grossAssets - netAssets;
        _exit(grossAssets, netAssets, fee, shares, receiver, onBehalf);
        return netAssets;
    }

    /// @dev Internal exit path. `assetsOut` total leaves the vault (split between `netAssets` to receiver and `fee`).
    /// @dev If idle liquidity (vault balance minus pending withdrawal claims) covers `assetsOut`, transfer
    /// immediately to `receiver`. Otherwise burn shares now and aggregate the request into
    /// `pendingWithdrawal[onBehalf]` — claim will later send the gross to `onBehalf` (not `receiver`).
    function _exit(
        uint256 assetsOut,
        uint256 netAssets,
        uint256 fee,
        uint256 shares,
        address receiver,
        address onBehalf
    ) internal {
        require(canSendShares(onBehalf), ErrorsLib.CannotSendShares());
        require(canReceiveAssets(receiver), ErrorsLib.CannotReceiveAssets());

        if (msg.sender != onBehalf) {
            uint256 _allowance = allowance[onBehalf][msg.sender];
            if (_allowance != type(uint256).max) allowance[onBehalf][msg.sender] = _allowance - shares;
        }

        deleteShares(onBehalf, shares);
        _totalAssets -= assetsOut.toUint128();

        uint256 idleAssets = IERC20(asset).balanceOf(address(this));
        uint256 effectiveIdle = idleAssets.zeroFloorSub(pendingClaimableAssets);

        if (effectiveIdle >= assetsOut) {
            // Immediate path: send fee then net to receiver.
            if (fee > 0) {
                require(protocolFeeRecipient != address(0), ErrorsLib.FeeInvariantBroken());
                SafeERC20Lib.safeTransfer(asset, protocolFeeRecipient, fee);
            }
            SafeERC20Lib.safeTransfer(asset, receiver, netAssets);
            emit EventsLib.Withdraw(msg.sender, receiver, onBehalf, netAssets, shares);
        } else {
            // Queue path: aggregate into the single per-user slot. Receiver argument is dropped
            // here — claim always sends to `onBehalf`. First request on this slot pays cold cost,
            // subsequent requests pay only the warm update cost (~5k gas).
            //
            // Fee snapshot policy: lock `feeAtRequest` to the current `withdrawalFee` on the first
            // request, and weighted-average it on subsequent requests so each batch contributes its
            // own fee fairly. This insulates the user from `setWithdrawalFee` changes that happen
            // AFTER they queued, while keeping a single accumulating slot.
            PendingWithdrawal storage p = pendingWithdrawal[onBehalf];
            uint256 oldAssets = p.assets;
            uint64 newFee = uint64(withdrawalFee);
            if (oldAssets == 0) {
                p.feeAtRequest = newFee;
            } else if (newFee != p.feeAtRequest) {
                // weighted by assets: (oldAssets*oldFee + assetsOut*newFee) / (oldAssets + assetsOut)
                p.feeAtRequest = uint64(
                    (oldAssets * uint256(p.feeAtRequest) + assetsOut * uint256(newFee)) / (oldAssets + assetsOut)
                );
            }
            p.assets = (oldAssets + assetsOut).toUint128();
            p.shares = (uint256(p.shares) + shares).toUint128();
            pendingClaimableAssets += assetsOut;
            emit EventsLib.WithdrawalRequested(msg.sender, onBehalf, assetsOut, shares);
        }
    }

    /// @notice Operator step (ERC-7540 / Centrifuge style): moves each user's full pending request into their
    /// reserved `claimableAssets`, locking the backing liquidity per-user. The ALLOCATOR controls fulfillment
    /// order by choosing which users — and in what sequence — to pass. A request is NOT claimable until fulfilled.
    /// @dev Reverts if a user has no pending request, or if unreserved idle (`balance - reservedAssets`) does not
    /// cover their pending amount. Shares were already burned at request time, so only assets move here.
    function fulfillWithdrawal(address[] calldata onBehalfs) external onlyRole(ALLOCATOR_ROLE) {
        uint256 len = onBehalfs.length;
        for (uint256 i; i < len;) {
            address onBehalf = onBehalfs[i];
            PendingWithdrawal memory p = pendingWithdrawal[onBehalf];
            uint256 amt = p.assets;
            require(amt > 0, ErrorsLib.RequestNotPending());
            require(
                IERC20(asset).balanceOf(address(this)) - reservedAssets >= amt, ErrorsLib.InsufficientLiquidity()
            );

            reservedAssets += amt;

            // Move the locked fee snapshot from pending into claimable. If the user already had
            // unclaimed assets at a different locked fee, weighted-average by assets so each batch
            // keeps its own fee contribution.
            uint256 oldClaim = claimableAssets[onBehalf];
            uint64 oldFee = claimableFee[onBehalf];
            if (oldClaim == 0) {
                claimableFee[onBehalf] = p.feeAtRequest;
            } else if (oldFee != p.feeAtRequest) {
                claimableFee[onBehalf] =
                    uint64((oldClaim * uint256(oldFee) + amt * uint256(p.feeAtRequest)) / (oldClaim + amt));
            }
            claimableAssets[onBehalf] = uint128(oldClaim + amt);
            delete pendingWithdrawal[onBehalf];
            emit EventsLib.WithdrawalFulfilled(onBehalf, amt);
            unchecked { ++i; }
        }
    }

    /// @notice Partial-fulfillment variant: move a chosen `amounts[i]` of each `onBehalfs[i]`'s pending
    /// request into their claimable balance (instead of the full pending amount). The remainder stays in
    /// the queue for a later round. Useful when underlying liquidity arrives in batches (e.g. an RWA
    /// custodian selling gold over multiple settlements) and the operator wants to flow it through to
    /// requesters proportionally as it becomes available.
    /// @dev Reverts if any `amounts[i]` exceeds that user's `pendingWithdrawal.assets`, or if the
    /// requested total would exceed the unreserved idle balance. `pendingWithdrawal.shares` is reduced
    /// proportionally (rounded down) so the per-user "burned shares" record stays consistent with the
    /// remaining `assets`. The locked `feeAtRequest` on pending does NOT change (it was set at queue
    /// time) and is propagated into `claimableFee` via the same weighted-average rule as the full
    /// fulfill path.
    function fulfillWithdrawalPartial(address[] calldata onBehalfs, uint256[] calldata amounts)
        external
        onlyRole(ALLOCATOR_ROLE)
    {
        require(onBehalfs.length == amounts.length, ErrorsLib.InvalidRequest());

        uint256 len = onBehalfs.length;
        for (uint256 i; i < len;) {
            address onBehalf = onBehalfs[i];
            uint256 amt = amounts[i];

            PendingWithdrawal memory p = pendingWithdrawal[onBehalf];
            require(amt > 0 && amt <= p.assets, ErrorsLib.InvalidRequest());
            require(
                IERC20(asset).balanceOf(address(this)) - reservedAssets >= amt, ErrorsLib.InsufficientLiquidity()
            );

            reservedAssets += amt;

            // Weighted-average fee merge (same rule as the full-fulfill path).
            uint256 oldClaim = claimableAssets[onBehalf];
            uint64 oldFee = claimableFee[onBehalf];
            if (oldClaim == 0) {
                claimableFee[onBehalf] = p.feeAtRequest;
            } else if (oldFee != p.feeAtRequest) {
                claimableFee[onBehalf] =
                    uint64((oldClaim * uint256(oldFee) + amt * uint256(p.feeAtRequest)) / (oldClaim + amt));
            }
            claimableAssets[onBehalf] = uint128(oldClaim + amt);

            // Reduce pending. If we drained it, delete the slot to free storage; otherwise shrink
            // assets/shares proportionally and leave feeAtRequest as-is.
            uint256 newAssets = uint256(p.assets) - amt;
            if (newAssets == 0) {
                delete pendingWithdrawal[onBehalf];
            } else {
                // shares ↓ in the same proportion as assets ↓ (round down — favors vault by leaving
                // marginally more shares-per-asset recorded on the user's still-pending balance).
                uint256 newShares = (uint256(p.shares) * newAssets) / uint256(p.assets);
                PendingWithdrawal storage ps = pendingWithdrawal[onBehalf];
                ps.assets = newAssets.toUint128();
                ps.shares = newShares.toUint128();
                // ps.feeAtRequest unchanged
            }

            emit EventsLib.WithdrawalFulfilled(onBehalf, amt);
            unchecked { ++i; }
        }
    }

    /// @notice Settles a fulfilled (reserved) withdrawal of `onBehalf`. Permissionless — anyone may trigger,
    /// assets always flow to `onBehalf` (not msg.sender). Payout is bounded by the operator-reserved
    /// `claimableAssets[onBehalf]`, never the shared balance, so a fulfilled request cannot be jumped.
    /// @dev The withdrawal fee is re-derived from the current `withdrawalFee` at claim time, not at request time.
    function claim(address onBehalf) external returns (uint256) {
        uint256 assetsOut = claimableAssets[onBehalf];
        require(assetsOut > 0, ErrorsLib.RequestNotPending());
        require(IERC20(asset).balanceOf(address(this)) >= assetsOut, ErrorsLib.InsufficientLiquidity());

        // Use the fee snapshotted at request/fulfillment time, not the current `withdrawalFee`.
        // Protects queued users from fee policy changes that happen between request and claim.
        uint256 lockedFee = claimableFee[onBehalf];
        claimableAssets[onBehalf] = 0;
        delete claimableFee[onBehalf];
        reservedAssets -= assetsOut;
        pendingClaimableAssets -= assetsOut;

        uint256 fee = assetsOut.mulDivUp(lockedFee, WAD);
        uint256 netAssets = assetsOut - fee;
        if (fee > 0) {
            require(protocolFeeRecipient != address(0), ErrorsLib.FeeInvariantBroken());
            SafeERC20Lib.safeTransfer(asset, protocolFeeRecipient, fee);
        }

        SafeERC20Lib.safeTransfer(asset, onBehalf, netAssets);
        emit EventsLib.WithdrawalClaimed(onBehalf, netAssets);
        return netAssets;
    }

    /// @notice Returns true iff `onBehalf` has an operator-fulfilled (reserved) amount ready to claim.
    function isClaimable(address onBehalf) external view returns (bool) {
        return claimableAssets[onBehalf] > 0;
    }

    /// @notice Aggregate liquidity immediately available for new withdrawals:
    /// vault idle balance (minus pending queue obligations) plus on-demand strategy liquidity.
    function availableLiquidity() external view returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this)).zeroFloorSub(pendingClaimableAssets);
        if (strategyManager != address(0)) {
            idle += IStrategyManager(strategyManager).availableStrategyLiquidity();
        }
        return idle;
    }

    /// @dev Returns shares burned as penalty.
    /// @dev Penalty is taken from `onBehalf` to discourage allocation manipulations. Shares are burned
    /// in place and the corresponding underlying stays in the vault (already there from the deallocate),
    /// so totalAssets decreases proportionally with totalSupply (share price ≈ unchanged) while the
    /// actually-held asset balance is preserved.
    /// @dev Implemented directly (not via `withdraw`) so it always settles in the immediate path, never
    /// entering the per-user withdrawal queue.
    function forceDeallocate(address strategy, bytes memory data, uint256 assets, address onBehalf)
        external
        returns (uint256)
    {
        bytes32[] memory ids = deallocateInternal(strategy, data, assets);

        uint256 penaltyAssets =
            assets.mulDivUp(IStrategyManager(strategyManager).forceDeallocatePenalty(strategy), WAD);
        accrueInterest();
        uint256 penaltyShares = previewWithdraw(penaltyAssets);

        require(canSendShares(onBehalf), ErrorsLib.CannotSendShares());

        if (msg.sender != onBehalf) {
            uint256 _allowance = allowance[onBehalf][msg.sender];
            if (_allowance != type(uint256).max) allowance[onBehalf][msg.sender] = _allowance - penaltyShares;
        }

        deleteShares(onBehalf, penaltyShares);
        _totalAssets -= penaltyAssets.toUint128();

        emit EventsLib.ForceDeallocate(msg.sender, strategy, assets, onBehalf, ids, penaltyAssets);
        return penaltyShares;
    }

    /* ERC20 FUNCTIONS */

    /// @dev Returns success (always true because reverts on failure).
    function transfer(address to, uint256 shares) external returns (bool) {
        require(to != address(0), ErrorsLib.ZeroAddress());

        require(canSendShares(msg.sender), ErrorsLib.CannotSendShares());
        require(canReceiveShares(to), ErrorsLib.CannotReceiveShares());

        balanceOf[msg.sender] -= shares;
        balanceOf[to] += shares;
        emit EventsLib.Transfer(msg.sender, to, shares);
        return true;
    }

    /// @dev Returns success (always true because reverts on failure).
    function transferFrom(address from, address to, uint256 shares) external returns (bool) {
        require(from != address(0), ErrorsLib.ZeroAddress());
        require(to != address(0), ErrorsLib.ZeroAddress());

        require(canSendShares(from), ErrorsLib.CannotSendShares());
        require(canReceiveShares(to), ErrorsLib.CannotReceiveShares());

        if (msg.sender != from) {
            uint256 _allowance = allowance[from][msg.sender];
            if (_allowance != type(uint256).max) {
                allowance[from][msg.sender] = _allowance - shares;
                emit EventsLib.AllowanceUpdatedByTransferFrom(from, msg.sender, _allowance - shares);
            }
        }

        balanceOf[from] -= shares;
        balanceOf[to] += shares;
        emit EventsLib.Transfer(from, to, shares);
        return true;
    }

    /// @dev Returns success (always true because reverts on failure).
    function approve(address spender, uint256 shares) external returns (bool) {
        allowance[msg.sender][spender] = shares;
        emit EventsLib.Approval(msg.sender, spender, shares);
        return true;
    }

    /// @dev Signature malleability is not explicitly prevented but it is not a problem thanks to the nonce.
    function permit(address _owner, address spender, uint256 shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(deadline >= block.timestamp, ErrorsLib.PermitDeadlineExpired());

        uint256 nonce = nonces[_owner]++;
        bytes32 hashStruct = keccak256(abi.encode(PERMIT_TYPEHASH, _owner, spender, shares, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), hashStruct));
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == _owner, ErrorsLib.InvalidSigner());

        allowance[_owner][spender] = shares;
        emit EventsLib.Approval(_owner, spender, shares);
        emit EventsLib.Permit(_owner, spender, shares, nonce, deadline);
    }

    function createShares(address to, uint256 shares) internal {
        require(to != address(0), ErrorsLib.ZeroAddress());
        balanceOf[to] += shares;
        totalSupply += shares;
        emit EventsLib.Transfer(address(0), to, shares);
    }

    function deleteShares(address from, uint256 shares) internal {
        require(from != address(0), ErrorsLib.ZeroAddress());
        balanceOf[from] -= shares;
        totalSupply -= shares;
        emit EventsLib.Transfer(from, address(0), shares);
    }

    /* PERMISSIONED TOKEN FUNCTIONS */

    function canReceiveShares(address account) public view returns (bool) {
        return receiveSharesGate == address(0) || IReceiveSharesGate(receiveSharesGate).canReceiveShares(account);
    }

    function canSendShares(address account) public view returns (bool) {
        return sendSharesGate == address(0) || ISendSharesGate(sendSharesGate).canSendShares(account);
    }

    function canReceiveAssets(address account) public view returns (bool) {
        return account == address(this) || receiveAssetsGate == address(0)
            || IReceiveAssetsGate(receiveAssetsGate).canReceiveAssets(account);
    }

    function canSendAssets(address account) public view returns (bool) {
        return sendAssetsGate == address(0) || ISendAssetsGate(sendAssetsGate).canSendAssets(account);
    }
}
