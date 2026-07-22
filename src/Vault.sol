// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IVault, PendingWithdrawal, RebalanceAction} from "./interfaces/IVault.sol";
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

    struct ClaimableWithdrawal {
        uint128 assets;
        uint64 fee;
    }

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

    /// @dev Strategy configuration and cap accounting live in StrategyManager.

    /* FEES STORAGE */

    uint96 public performanceFee;
    address public performanceFeeRecipient;
    uint96 public managementFee;
    address public managementFeeRecipient;
    /// @dev Deposit fee in WAD units.
    uint96 public depositFee;
    /// @dev Withdrawal fee in WAD units.
    uint96 public withdrawalFee;
    /// @dev Recipient for deposit and withdrawal fees.
    address public protocolFeeRecipient;

    /* WITHDRAWAL QUEUE STORAGE */

    /// @dev Per-receiver withdrawal queue entry. Requests sharing a receiver accumulate.
    mapping(address receiver => PendingWithdrawal) public pendingWithdrawal;
    /// @dev Assets and fee snapshots reserved for fulfilled withdrawals.
    mapping(address receiver => ClaimableWithdrawal) internal _claimableWithdrawal;
    /// @dev Total assets reserved for fulfilled withdrawals.
    uint256 public reservedAssets;
    /// @dev Total asset liabilities fixed at fulfillment and awaiting claim. Pending share requests are excluded.
    uint256 public pendingClaimableAssets;

    /* PAUSE STORAGE */

    /// @dev When true, deposits and allocations are paused.
    bool public paused;

    modifier whenNotPaused() {
        require(!paused, ErrorsLib.Paused());
        _;
    }

    /* GETTERS */

    /// @dev Strategy views are exposed through StrategyManager.

    function totalAssets() external view returns (uint256) {
        (uint256 newTotalAssets,,) = accrueInterestView();
        return newTotalAssets;
    }

    function claimableAssets(address receiver) external view returns (uint128) {
        return _claimableWithdrawal[receiver].assets;
    }

    function claimableFee(address receiver) external view returns (uint64) {
        return _claimableWithdrawal[receiver].fee;
    }

    /// @notice Current net-asset estimate for a pending share request. Final assets are fixed only at fulfillment.
    function previewPendingWithdrawal(address receiver) external view returns (uint256) {
        PendingWithdrawal memory p = pendingWithdrawal[receiver];
        if (p.shares == 0) return 0;
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        uint256 grossAssets = uint256(p.shares).mulDivDown(newTotalAssets + 1, newTotalSupply + virtualShares);
        return grossAssets - grossAssets.mulDivUp(p.feeAtRequest, WAD);
    }

    /// forge-lint: disable-next-item(mixed-case-function)
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    /* MULTICALL */

    /// @dev Convenience helper for batching vault calls.
    function multicall(bytes[] calldata data) external {
        uint256 len = data.length;
        for (uint256 i; i < len;) {
            (bool success, bytes memory returnData) = address(this).delegatecall(data[i]);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(32, returnData), mload(returnData))
                }
            }
            unchecked {
                ++i;
            }
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

    function setName(string calldata newName) external onlyRole(GOVERNANCE_ROLE) {
        name = newName;
        emit EventsLib.SetName(newName);
    }

    function setSymbol(string calldata newSymbol) external onlyRole(GOVERNANCE_ROLE) {
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

    /// @dev One-time hook for wiring the vault's StrategyManager.
    function setStrategyManager(address newStrategyManager) external onlyRole(GOVERNANCE_ROLE) {
        require(strategyManager == address(0), ErrorsLib.InvalidStrategyManager());
        require(newStrategyManager != address(0), ErrorsLib.ZeroAddress());
        require(newStrategyManager.code.length != 0, ErrorsLib.NoCode());
        require(IStrategyManager(newStrategyManager).vault() == address(this), ErrorsLib.InvalidStrategyManager());
        require(IStrategyManager(newStrategyManager).asset() == asset, ErrorsLib.InvalidStrategyManager());

        strategyManager = newStrategyManager;
        emit EventsLib.SetStrategyManager(newStrategyManager);
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

    /// @notice Pauses deposits and allocations.
    /// @dev Withdrawals remain available.
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

    function allocate(address strategy, bytes calldata data, uint256 assets)
        external
        whenNotPaused
        onlyRole(ALLOCATOR_ROLE)
    {
        allocateInternal(strategy, data, assets);
    }

    function allocateInternal(address strategy, bytes calldata data, uint256 assets) internal {
        address _strategyManager = strategyManager;
        require(_strategyManager != address(0), ErrorsLib.ZeroAddress());

        accrueInterest();

        // Do not allocate assets reserved for fulfilled withdrawals.
        require(
            assets <= IERC20(asset).balanceOf(address(this)).zeroFloorSub(reservedAssets),
            ErrorsLib.InsufficientLiquidity()
        );

        SafeERC20Lib.safeTransfer(asset, strategy, assets);
        (bytes32[] memory ids, int256 change) = IStrategy(strategy).allocate(data, assets, msg.sig, msg.sender);

        IStrategyManager(_strategyManager).onAllocate(strategy, ids, change, firstTotalAssets);

        emit EventsLib.Allocate(msg.sender, strategy, assets, ids, change);
    }

    function deallocate(address strategy, bytes calldata data, uint256 assets) external {
        _requireAnyRole(ALLOCATOR_ROLE, SENTINEL_ROLE);
        deallocateInternal(strategy, data, assets);
    }

    /// @notice Moves capital between strategies in a single batch (e.g. deallocate from one, allocate to
    /// another). Reverts the whole batch if any leg fails, so no partial moves can occur.
    /// @dev Allocate legs are blocked while paused (entry); deallocate legs (exit) stay available. Calling
    /// allocateInternal/deallocateInternal directly means the per-leg role checks are skipped — the single
    /// ALLOCATOR_ROLE gate here covers the whole batch.
    function rebalance(RebalanceAction[] calldata actions) external onlyRole(ALLOCATOR_ROLE) {
        uint256 len = actions.length;
        for (uint256 i; i < len;) {
            RebalanceAction calldata action = actions[i];
            if (action.isAllocate) {
                require(!paused, ErrorsLib.Paused());
                allocateInternal(action.strategy, action.data, action.assets);
            } else {
                deallocateInternal(action.strategy, action.data, action.assets);
            }
            unchecked {
                ++i;
            }
        }
        emit EventsLib.Rebalance(msg.sender, len);
    }

    function deallocateInternal(address strategy, bytes calldata data, uint256 assets)
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

    /// @notice Deliberate, governance-only immediate NAV reflection that bypasses the maxRate cap.
    /// @dev NOT a routine path. Routine NAV flows through `OffchainNAVStrategy.report()` and is
    /// smoothed by maxRate via `accrueInterest`. This forces `_totalAssets` to the full real value in
    /// one shot, removing the anti-jump guard — use only for trusted/authoritative marks or to correct
    /// a stuck price. Gated by GOVERNANCE_ROLE (timelocked in production); emits a distinct event.
    function forceSyncReportedNAV() external onlyRole(GOVERNANCE_ROLE) {
        uint256 newTotalAssets = _realAssets();
        uint256 previousTotalAssets = _totalAssets;
        (uint256 performanceFeeShares, uint256 managementFeeShares) =
            _previewFeeShares(previousTotalAssets, newTotalAssets, block.timestamp - lastUpdate);

        _applyAccruedTotalAssets(newTotalAssets, performanceFeeShares, managementFeeShares);
        emit EventsLib.ForceSyncReportedNAV(msg.sender, previousTotalAssets, newTotalAssets);
    }

    function _applyAccruedTotalAssets(uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares)
        internal
    {
        emit EventsLib.AccrueInterest(_totalAssets, newTotalAssets, performanceFeeShares, managementFeeShares);
        _totalAssets = newTotalAssets.toUint128();
        if (firstTotalAssets == 0) firstTotalAssets = newTotalAssets;
        if (performanceFeeShares != 0) createShares(performanceFeeRecipient, performanceFeeShares);
        if (managementFeeShares != 0) createShares(managementFeeRecipient, managementFeeShares);
        lastUpdate = uint64(block.timestamp);
    }

    /// @dev Returns accrued assets together with the fee shares to mint.
    /// Management fees accrue regardless of profit and both fee paths round down.
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
        managementFeeShares = managementFeeAssets.mulDivDown(totalSupply + virtualShares, newTotalAssetsWithoutFees + 1);
    }

    function _realAssets() internal view returns (uint256 realAssets) {
        // Pending share requests remain shareholder capital until fulfillment. Only fixed claimable
        // asset liabilities are excluded from shareholder NAV.
        realAssets = IERC20(asset).balanceOf(address(this));
        if (strategyManager != address(0)) realAssets += IStrategyManager(strategyManager).totalStrategyAssets();
        realAssets = realAssets.zeroFloorSub(pendingClaimableAssets);
    }

    function _hasBlockingStaleOffchainExposure() internal view returns (bool) {
        address _strategyManager = strategyManager;
        return _strategyManager != address(0)
            && IStrategyManager(_strategyManager).hasBlockingStaleOffchainExposure();
    }

    function _requireFreshOffchainStrategies() internal view {
        if (_hasBlockingStaleOffchainExposure()) revert ErrorsLib.StaleOffchainStrategy();
    }

    function _blendFee(uint256 oldAmt, uint64 oldFee, uint256 newAmt, uint64 newFee) internal pure returns (uint64) {
        if (oldAmt == 0) return newFee;
        if (oldFee == newFee) return oldFee;
        return uint64((oldAmt * uint256(oldFee) + newAmt * uint256(newFee)) / (oldAmt + newAmt));
    }

    /// @dev Returns the shares minted for `assets`, net of deposit fees.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        uint256 netAssets = assets - assets.mulDivUp(depositFee, WAD);
        return netAssets.mulDivDown(newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @dev Returns the gross assets required to mint `shares`.
    function previewMint(uint256 shares) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        uint256 netAssets = shares.mulDivUp(newTotalAssets + 1, newTotalSupply + virtualShares);
        return depositFee == 0 ? netAssets : netAssets.mulDivUp(WAD, WAD - depositFee);
    }

    /// @dev Returns the shares burned to withdraw `assets` after fees.
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        uint256 grossAssets = withdrawalFee == 0 ? assets : assets.mulDivUp(WAD, WAD - withdrawalFee);
        return grossAssets.mulDivUp(newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @dev Returns the assets received when redeeming `shares`.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        uint256 grossAssets = shares.mulDivDown(newTotalAssets + 1, newTotalSupply + virtualShares);
        return grossAssets - grossAssets.mulDivUp(withdrawalFee, WAD);
    }

    /// @dev Returns the fee-agnostic share amount for `assets`.
    function convertToShares(uint256 assets) external view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        return assets.mulDivDown(newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @dev Returns the fee-agnostic asset amount for `shares`.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        return shares.mulDivDown(newTotalAssets + 1, newTotalSupply + virtualShares);
    }

    /* MAX FUNCTIONS */

    /// @dev Returns zero because gate checks are not guaranteed to be revert-free.
    function maxDeposit(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Returns zero because gate checks are not guaranteed to be revert-free.
    function maxMint(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Returns zero because gate checks are not guaranteed to be revert-free.
    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Returns zero because gate checks are not guaranteed to be revert-free.
    function maxRedeem(address) external pure returns (uint256) {
        return 0;
    }

    /* USER MAIN FUNCTIONS */

    /// @dev Charges `depositFee` and mints shares against the net assets.
    function deposit(uint256 assets, address onBehalf) external whenNotPaused returns (uint256) {
        _requireFreshOffchainStrategies();
        accrueInterest();
        uint256 shares = previewDeposit(assets);
        uint256 fee = assets.mulDivUp(depositFee, WAD);
        uint256 netAssets = assets - fee;
        _enter(assets, netAssets, fee, shares, onBehalf);
        return shares;
    }

    /// @dev Mints `shares` to `onBehalf` for the required gross assets.
    function mint(uint256 shares, address onBehalf) external whenNotPaused returns (uint256) {
        _requireFreshOffchainStrategies();
        accrueInterest();
        uint256 grossAssets = previewMint(shares);
        uint256 fee = grossAssets.mulDivUp(depositFee, WAD);
        uint256 netAssets = grossAssets - fee;
        _enter(grossAssets, netAssets, fee, shares, onBehalf);
        return grossAssets;
    }

    /// @dev Internal entry path for deposits and mints.
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

    /// @dev Settles immediately when idle liquidity is sufficient; otherwise queues shares for later pricing.
    function withdraw(uint256 assets, address receiver, address onBehalf) public returns (uint256) {
        accrueInterest();
        uint256 shares = previewWithdraw(assets);
        uint256 grossAssets = withdrawalFee == 0 ? assets : assets.mulDivUp(WAD, WAD - withdrawalFee);
        uint256 fee = grossAssets - assets;
        _exit(grossAssets, assets, fee, shares, receiver, onBehalf);
        return shares;
    }

    /// @dev Settles immediately when idle liquidity is sufficient; otherwise queues shares for later pricing.
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256) {
        accrueInterest();
        uint256 netAssets = previewRedeem(shares);
        uint256 grossAssets = withdrawalFee == 0 ? netAssets : netAssets.mulDivUp(WAD, WAD - withdrawalFee);
        uint256 fee = grossAssets - netAssets;
        _exit(grossAssets, netAssets, fee, shares, receiver, onBehalf);
        return netAssets;
    }

    /// @dev Immediate exits burn at the request-time price. Only liquidity-short exits escrow shares;
    /// their request-time asset value is an estimate and the final value is set by fulfillment.
    function _exit(
        uint256 grossAssets,
        uint256 netAssets,
        uint256 fee,
        uint256 shares,
        address receiver,
        address onBehalf
    ) internal {
        require(onBehalf != address(0), ErrorsLib.ZeroAddress());
        require(canSendShares(onBehalf), ErrorsLib.CannotSendShares());
        require(canReceiveAssets(receiver), ErrorsLib.CannotReceiveAssets());

        if (msg.sender != onBehalf) {
            uint256 _allowance = allowance[onBehalf][msg.sender];
            if (_allowance != type(uint256).max) allowance[onBehalf][msg.sender] = _allowance - shares;
        }

        uint256 effectiveIdle = IERC20(asset).balanceOf(address(this)).zeroFloorSub(pendingClaimableAssets);
        if (effectiveIdle >= grossAssets && !_hasBlockingStaleOffchainExposure()) {
            // Only fresh request-time prices may settle immediately. A stale offchain mark forces the
            // request into the queue even when idle liquidity is sufficient.
            deleteShares(onBehalf, shares);
            _totalAssets -= grossAssets.toUint128();

            if (fee > 0) {
                require(protocolFeeRecipient != address(0), ErrorsLib.FeeInvariantBroken());
                SafeERC20Lib.safeTransfer(asset, protocolFeeRecipient, fee);
            }
            SafeERC20Lib.safeTransfer(asset, receiver, netAssets);
            emit EventsLib.Withdraw(msg.sender, receiver, onBehalf, netAssets, shares);
        } else {
            // Escrow rather than burn. Queued shares participate in gains/losses until fulfillment.
            balanceOf[onBehalf] -= shares;
            balanceOf[address(this)] += shares;
            emit EventsLib.Transfer(onBehalf, address(this), shares);

            PendingWithdrawal storage p = pendingWithdrawal[receiver];
            uint256 oldShares = p.shares;
            p.feeAtRequest = _blendFee(oldShares, p.feeAtRequest, shares, uint64(withdrawalFee));
            p.assets = (uint256(p.assets) + grossAssets).toUint128();
            p.shares = (oldShares + shares).toUint128();

            emit EventsLib.WithdrawalRequested(msg.sender, onBehalf, receiver, grossAssets, shares);
        }
    }

    /// @notice Prices and moves pending withdrawals into fixed claimable balances.
    /// @dev Requires fresh offchain NAV and enough unreserved idle liquidity for each request.
    function fulfillWithdrawal(address[] calldata receivers) external onlyRole(ALLOCATOR_ROLE) {
        _requireFreshOffchainStrategies();
        accrueInterest();

        uint256 len = receivers.length;
        IERC20 assetToken = IERC20(asset);
        uint256 balance = assetToken.balanceOf(address(this));
        uint256 reserved = reservedAssets;
        uint256 newReserved = reserved;
        uint256 settlementTotalAssets = _totalAssets;
        uint256 settlementTotalSupply = totalSupply;

        for (uint256 i; i < len;) {
            address receiver = receivers[i];
            require(canReceiveAssets(receiver), ErrorsLib.CannotReceiveAssets());
            PendingWithdrawal memory p = pendingWithdrawal[receiver];
            uint256 shares = p.shares;
            require(shares > 0, ErrorsLib.RequestNotPending());
            uint256 amt = _convertToAssetsSettled(shares, settlementTotalAssets, settlementTotalSupply);
            require(balance - newReserved >= amt, ErrorsLib.InsufficientLiquidity());

            newReserved += amt;
            pendingClaimableAssets += amt;
            _totalAssets -= amt.toUint128();
            deleteShares(address(this), shares);

            // Merge the queued fee snapshot into the claimable balance.
            ClaimableWithdrawal storage claimable = _claimableWithdrawal[receiver];
            uint256 oldClaim = claimable.assets;
            claimable.fee = _blendFee(oldClaim, claimable.fee, amt, p.feeAtRequest);
            claimable.assets = (oldClaim + amt).toUint128();
            delete pendingWithdrawal[receiver];
            emit EventsLib.WithdrawalFulfilled(receiver, amt, shares);
            unchecked {
                ++i;
            }
        }

        if (newReserved != reserved) reservedAssets = newReserved;
    }

    /// @notice Prices and partially fulfills a specified number of pending shares.
    /// @dev Any remaining shares stay queued with the original fee snapshot.
    function fulfillWithdrawalPartial(address[] calldata receivers, uint256[] calldata sharesToFulfill)
        external
        onlyRole(ALLOCATOR_ROLE)
    {
        require(receivers.length == sharesToFulfill.length, ErrorsLib.InvalidRequest());
        _requireFreshOffchainStrategies();
        accrueInterest();

        uint256 len = receivers.length;
        IERC20 assetToken = IERC20(asset);
        uint256 balance = assetToken.balanceOf(address(this));
        uint256 reserved = reservedAssets;
        uint256 newReserved = reserved;
        uint256 settlementTotalAssets = _totalAssets;
        uint256 settlementTotalSupply = totalSupply;

        for (uint256 i; i < len;) {
            address receiver = receivers[i];
            uint256 shares = sharesToFulfill[i];

            require(canReceiveAssets(receiver), ErrorsLib.CannotReceiveAssets());
            PendingWithdrawal memory p = pendingWithdrawal[receiver];
            require(shares > 0 && shares <= p.shares, ErrorsLib.InvalidRequest());
            uint256 amt = _convertToAssetsSettled(shares, settlementTotalAssets, settlementTotalSupply);
            require(balance - newReserved >= amt, ErrorsLib.InsufficientLiquidity());

            newReserved += amt;
            pendingClaimableAssets += amt;
            _totalAssets -= amt.toUint128();
            deleteShares(address(this), shares);

            // Merge the fee snapshot into the claimable balance.
            ClaimableWithdrawal storage claimable = _claimableWithdrawal[receiver];
            uint256 oldClaim = claimable.assets;
            claimable.fee = _blendFee(oldClaim, claimable.fee, amt, p.feeAtRequest);
            claimable.assets = (oldClaim + amt).toUint128();

            // Reduce remaining escrowed shares. The assets field remains an estimate only.
            uint256 newShares = uint256(p.shares) - shares;
            if (newShares == 0) {
                delete pendingWithdrawal[receiver];
            } else {
                PendingWithdrawal storage ps = pendingWithdrawal[receiver];
                ps.assets = uint256(p.assets).mulDivDown(newShares, p.shares).toUint128();
                ps.shares = newShares.toUint128();
            }

            emit EventsLib.WithdrawalFulfilled(receiver, amt, shares);
            unchecked {
                ++i;
            }
        }

        if (newReserved != reserved) reservedAssets = newReserved;
    }

    /// @dev Converts shares at the already-accrued fulfillment price, before those shares are burned.
    function _convertToAssetsSettled(uint256 shares, uint256 settlementTotalAssets, uint256 settlementTotalSupply)
        internal
        view
        returns (uint256)
    {
        return shares.mulDivDown(settlementTotalAssets + 1, settlementTotalSupply + virtualShares);
    }

    /// @notice Settles a fulfilled withdrawal for `receiver`.
    /// @dev Uses the fee snapshot stored when the request was queued and fulfilled.
    function claim(address receiver) external returns (uint256) {
        ClaimableWithdrawal memory claimable = _claimableWithdrawal[receiver];
        uint256 assetsOut = claimable.assets;
        require(assetsOut > 0, ErrorsLib.RequestNotPending());
        require(IERC20(asset).balanceOf(address(this)) >= assetsOut, ErrorsLib.InsufficientLiquidity());
        require(canReceiveAssets(receiver), ErrorsLib.CannotReceiveAssets());

        // Use the stored fee snapshot rather than the current withdrawal fee.
        uint256 lockedFee = claimable.fee;
        delete _claimableWithdrawal[receiver];
        reservedAssets -= assetsOut;
        pendingClaimableAssets -= assetsOut;

        uint256 fee = assetsOut.mulDivUp(lockedFee, WAD);
        uint256 netAssets = assetsOut - fee;
        if (fee > 0) {
            require(protocolFeeRecipient != address(0), ErrorsLib.FeeInvariantBroken());
            SafeERC20Lib.safeTransfer(asset, protocolFeeRecipient, fee);
        }

        SafeERC20Lib.safeTransfer(asset, receiver, netAssets);
        emit EventsLib.WithdrawalClaimed(receiver, netAssets);
        return netAssets;
    }

    /// @notice Returns whether `receiver` has claimable assets.
    function isClaimable(address receiver) external view returns (bool) {
        return _claimableWithdrawal[receiver].assets > 0;
    }

    /// @notice Returns aggregate liquidity available for withdrawals.
    function availableLiquidity() external view returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this)).zeroFloorSub(pendingClaimableAssets);
        if (strategyManager != address(0)) {
            idle += IStrategyManager(strategyManager).availableStrategyLiquidity();
        }
        return idle;
    }

    /// @dev Burns shares as a force-deallocation penalty.
    /// The penalty is settled immediately and never enters the withdrawal queue.
    function forceDeallocate(address strategy, bytes calldata data, uint256 assets, address onBehalf)
        external
        returns (uint256)
    {
        require(
            !IStrategyManager(strategyManager).isOffchainStrategy(strategy),
            ErrorsLib.ForceDeallocateUnsupported()
        );
        bytes32[] memory ids = deallocateInternal(strategy, data, assets);

        uint256 penaltyAssets = assets.mulDivUp(IStrategyManager(strategyManager).forceDeallocatePenalty(strategy), WAD);
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

    /// @dev Always returns true on success.
    function transfer(address to, uint256 shares) external returns (bool) {
        require(to != address(0), ErrorsLib.ZeroAddress());

        require(canSendShares(msg.sender), ErrorsLib.CannotSendShares());
        require(canReceiveShares(to), ErrorsLib.CannotReceiveShares());

        balanceOf[msg.sender] -= shares;
        balanceOf[to] += shares;
        emit EventsLib.Transfer(msg.sender, to, shares);
        return true;
    }

    /// @dev Always returns true on success.
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

    /// @dev Always returns true on success.
    function approve(address spender, uint256 shares) external returns (bool) {
        allowance[msg.sender][spender] = shares;
        emit EventsLib.Approval(msg.sender, spender, shares);
        return true;
    }

    /// @dev Nonces prevent replay even if a signature is malleable.
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
