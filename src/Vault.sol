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

    /// @dev Per-user withdrawal queue entry.
    mapping(address onBehalf => PendingWithdrawal) public pendingWithdrawal;
    /// @dev Assets and fee snapshots reserved for fulfilled withdrawals.
    mapping(address onBehalf => ClaimableWithdrawal) internal _claimableWithdrawal;
    /// @dev Total assets reserved for fulfilled withdrawals.
    uint256 public reservedAssets;
    /// @dev Total assets owed to queued or fulfilled withdrawals.
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

    function claimableAssets(address onBehalf) external view returns (uint128) {
        return _claimableWithdrawal[onBehalf].assets;
    }

    function claimableFee(address onBehalf) external view returns (uint64) {
        return _claimableWithdrawal[onBehalf].fee;
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
        // Subtract pending claims — they no longer belong to share holders.
        realAssets = IERC20(asset).balanceOf(address(this))
            .zeroFloorSub(pendingClaimableAssets);
        if (strategyManager != address(0)) realAssets += IStrategyManager(strategyManager).totalStrategyAssets();
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
        accrueInterest();
        uint256 shares = previewDeposit(assets);
        uint256 fee = assets.mulDivUp(depositFee, WAD);
        uint256 netAssets = assets - fee;
        _enter(assets, netAssets, fee, shares, onBehalf);
        return shares;
    }

    /// @dev Mints `shares` to `onBehalf` for the required gross assets.
    function mint(uint256 shares, address onBehalf) external whenNotPaused returns (uint256) {
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

    /// @dev Withdraws `assets` net of fees to `receiver`.
    function withdraw(uint256 assets, address receiver, address onBehalf) public returns (uint256) {
        accrueInterest();
        uint256 shares = previewWithdraw(assets);
        uint256 grossAssets = withdrawalFee == 0 ? assets : assets.mulDivUp(WAD, WAD - withdrawalFee);
        uint256 fee = grossAssets - assets;
        _exit(grossAssets, assets, fee, shares, receiver, onBehalf);
        return shares;
    }

    /// @dev Redeems `shares` from `onBehalf`.
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256) {
        accrueInterest();
        uint256 netAssets = previewRedeem(shares);
        uint256 grossAssets = withdrawalFee == 0 ? netAssets : netAssets.mulDivUp(WAD, WAD - withdrawalFee);
        uint256 fee = grossAssets - netAssets;
        _exit(grossAssets, netAssets, fee, shares, receiver, onBehalf);
        return netAssets;
    }

    /// @dev Internal exit path for withdrawals and redeems.
    /// Uses the queue when idle liquidity is insufficient.
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
            // Immediate settlement.
            if (fee > 0) {
                require(protocolFeeRecipient != address(0), ErrorsLib.FeeInvariantBroken());
                SafeERC20Lib.safeTransfer(asset, protocolFeeRecipient, fee);
            }
            SafeERC20Lib.safeTransfer(asset, receiver, netAssets);
            emit EventsLib.Withdraw(msg.sender, receiver, onBehalf, netAssets, shares);
        } else {
            // Queue settlement and snapshot the fee in effect for this request.
            PendingWithdrawal storage p = pendingWithdrawal[onBehalf];
            uint256 oldAssets = p.assets;
            uint64 newFee = uint64(withdrawalFee);
            if (oldAssets == 0) {
                p.feeAtRequest = newFee;
            } else if (newFee != p.feeAtRequest) {
                // Weighted by assets.
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

    /// @notice Moves pending withdrawals into claimable balances.
    /// @dev Requires enough unreserved idle liquidity for each request.
    function fulfillWithdrawal(address[] calldata onBehalfs) external onlyRole(ALLOCATOR_ROLE) {
        uint256 len = onBehalfs.length;
        IERC20 assetToken = IERC20(asset);
        uint256 balance = assetToken.balanceOf(address(this));
        uint256 reserved = reservedAssets;
        uint256 newReserved = reserved;

        for (uint256 i; i < len;) {
            address onBehalf = onBehalfs[i];
            PendingWithdrawal memory p = pendingWithdrawal[onBehalf];
            uint256 amt = p.assets;
            require(amt > 0, ErrorsLib.RequestNotPending());
            require(balance - newReserved >= amt, ErrorsLib.InsufficientLiquidity());

            newReserved += amt;

            // Merge the queued fee snapshot into the claimable balance.
            ClaimableWithdrawal storage claimable = _claimableWithdrawal[onBehalf];
            uint256 oldClaim = claimable.assets;
            uint64 oldFee = claimable.fee;
            if (oldClaim == 0) {
                claimable.fee = p.feeAtRequest;
            } else if (oldFee != p.feeAtRequest) {
                claimable.fee = uint64((oldClaim * uint256(oldFee) + amt * uint256(p.feeAtRequest)) / (oldClaim + amt));
            }
            claimable.assets = uint128(oldClaim + amt);
            delete pendingWithdrawal[onBehalf];
            emit EventsLib.WithdrawalFulfilled(onBehalf, amt);
            unchecked {
                ++i;
            }
        }

        if (newReserved != reserved) reservedAssets = newReserved;
    }

    /// @notice Partially fulfills pending withdrawals.
    /// @dev Any remaining balance stays queued with the original fee snapshot.
    function fulfillWithdrawalPartial(address[] calldata onBehalfs, uint256[] calldata amounts)
        external
        onlyRole(ALLOCATOR_ROLE)
    {
        require(onBehalfs.length == amounts.length, ErrorsLib.InvalidRequest());

        uint256 len = onBehalfs.length;
        IERC20 assetToken = IERC20(asset);
        uint256 balance = assetToken.balanceOf(address(this));
        uint256 reserved = reservedAssets;
        uint256 newReserved = reserved;

        for (uint256 i; i < len;) {
            address onBehalf = onBehalfs[i];
            uint256 amt = amounts[i];

            PendingWithdrawal memory p = pendingWithdrawal[onBehalf];
            require(amt > 0 && amt <= p.assets, ErrorsLib.InvalidRequest());
            require(balance - newReserved >= amt, ErrorsLib.InsufficientLiquidity());

            newReserved += amt;

            // Merge the fee snapshot into the claimable balance.
            ClaimableWithdrawal storage claimable = _claimableWithdrawal[onBehalf];
            uint256 oldClaim = claimable.assets;
            uint64 oldFee = claimable.fee;
            if (oldClaim == 0) {
                claimable.fee = p.feeAtRequest;
            } else if (oldFee != p.feeAtRequest) {
                claimable.fee = uint64((oldClaim * uint256(oldFee) + amt * uint256(p.feeAtRequest)) / (oldClaim + amt));
            }
            claimable.assets = uint128(oldClaim + amt);

            // Reduce the remaining queued balance.
            uint256 newAssets = uint256(p.assets) - amt;
            if (newAssets == 0) {
                delete pendingWithdrawal[onBehalf];
            } else {
                // Keep shares in proportion to the remaining assets.
                uint256 newShares = (uint256(p.shares) * newAssets) / uint256(p.assets);
                PendingWithdrawal storage ps = pendingWithdrawal[onBehalf];
                ps.assets = newAssets.toUint128();
                ps.shares = newShares.toUint128();
            }

            emit EventsLib.WithdrawalFulfilled(onBehalf, amt);
            unchecked {
                ++i;
            }
        }

        if (newReserved != reserved) reservedAssets = newReserved;
    }

    /// @notice Settles a fulfilled withdrawal for `onBehalf`.
    /// @dev Uses the fee snapshot stored when the request was queued and fulfilled.
    function claim(address onBehalf) external returns (uint256) {
        ClaimableWithdrawal memory claimable = _claimableWithdrawal[onBehalf];
        uint256 assetsOut = claimable.assets;
        require(assetsOut > 0, ErrorsLib.RequestNotPending());
        require(IERC20(asset).balanceOf(address(this)) >= assetsOut, ErrorsLib.InsufficientLiquidity());

        // Use the stored fee snapshot rather than the current withdrawal fee.
        uint256 lockedFee = claimable.fee;
        delete _claimableWithdrawal[onBehalf];
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

    /// @notice Returns whether `onBehalf` has claimable assets.
    function isClaimable(address onBehalf) external view returns (bool) {
        return _claimableWithdrawal[onBehalf].assets > 0;
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
