// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Copyright (c) 2026 Ontorium
//
// Modified by Ontorium in 2026.
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IGovernanceTimelock} from "./interfaces/IGovernanceTimelock.sol";
import {IVault, WithdrawalRequest} from "./interfaces/IVault.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IStrategyManager} from "./interfaces/IStrategyManager.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import "./libraries/ConstantsLib.sol"; 
import {MathLib} from "./libraries/MathLib.sol";
import {SafeERC20Lib} from "./libraries/SafeERC20Lib.sol";
import {IReceiveSharesGate, ISendSharesGate, IReceiveAssetsGate, ISendAssetsGate} from "./interfaces/IGate.sol";

contract Vault is IVault {
    using MathLib for uint256;
    using MathLib for uint128;
    using MathLib for int256;

    /* IMMUTABLE */

    address public immutable asset;
    uint8 public immutable decimals;
    uint256 public immutable virtualShares;

    /* ROLES STORAGE */

    address public owner;
    address public receiveSharesGate;
    address public sendSharesGate;
    address public receiveAssetsGate;
    address public sendAssetsGate;
    address public strategyManager;
    mapping(address account => bool) public isAllocator;

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

    /* WITHDRAWAL QUEUE STORAGE */

    mapping(uint256 requestId => WithdrawalRequest) public withdrawalRequests;
    uint256 public nextRequestId;
    /// @dev Assets earmarked for unclaimed withdrawal requests. Subtracted from idle balance when
    /// computing liquidity available for immediate withdrawals and from realAssets in interest accrual.
    uint256 public pendingClaimableAssets;

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
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory returnData) = address(this).delegatecall(data[i]);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(32, returnData), mload(returnData))
                }
            }
        }
    }

    /* CONSTRUCTOR */

    constructor(address _owner, address _asset) {
        asset = _asset;
        owner = _owner;
        lastUpdate = uint64(block.timestamp);
        uint256 assetDecimals = IERC20(_asset).decimals();
        uint256 decimalOffset = uint256(18).zeroFloorSub(assetDecimals);
        // forge-lint: disable-next-item(unsafe-typecast) safe because assetDecimals + decimalOffset <= 18.
        decimals = uint8(assetDecimals + decimalOffset);
        virtualShares = 10 ** decimalOffset;
        emit EventsLib.Constructor(_owner, _asset);
    }

    /* OWNER FUNCTIONS */

    function setOwner(address newOwner) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        owner = newOwner;
        emit EventsLib.SetOwner(newOwner);
    }

    function setName(string memory newName) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        name = newName;
        emit EventsLib.SetName(newName);
    }

    function setSymbol(string memory newSymbol) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        symbol = newSymbol;
        emit EventsLib.SetSymbol(newSymbol);
    }

    function setIsAllocator(address account, bool newIsAllocator) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        isAllocator[account] = newIsAllocator;
        emit EventsLib.SetIsAllocator(account, newIsAllocator);
    }

    function setReceiveSharesGate(address newReceiveSharesGate) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        receiveSharesGate = newReceiveSharesGate;
        emit EventsLib.SetReceiveSharesGate(newReceiveSharesGate);
    }

    function setSendSharesGate(address newSendSharesGate) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        sendSharesGate = newSendSharesGate;
        emit EventsLib.SetSendSharesGate(newSendSharesGate);
    }

    function setReceiveAssetsGate(address newReceiveAssetsGate) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        receiveAssetsGate = newReceiveAssetsGate;
        emit EventsLib.SetReceiveAssetsGate(newReceiveAssetsGate);
    }

    function setSendAssetsGate(address newSendAssetsGate) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        sendAssetsGate = newSendAssetsGate;
        emit EventsLib.SetSendAssetsGate(newSendAssetsGate);
    }

    /// @dev One-time setup so the factory can atomically deploy and link a dedicated StrategyManager.
    /// @dev The manager must explicitly point back to this Vault and use the same asset.
    function setStrategyManager(address newStrategyManager) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        require(strategyManager == address(0), ErrorsLib.InvalidStrategyManager());
        require(newStrategyManager != address(0), ErrorsLib.ZeroAddress());
        require(newStrategyManager.code.length != 0, ErrorsLib.NoCode());
        require(IStrategyManager(newStrategyManager).vault() == address(this), ErrorsLib.InvalidStrategyManager());
        require(IStrategyManager(newStrategyManager).asset() == asset, ErrorsLib.InvalidStrategyManager());

        strategyManager = newStrategyManager;
        emit EventsLib.SetStrategyManager(newStrategyManager);
    }

    function setPerformanceFee(uint256 newPerformanceFee) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        require(newPerformanceFee <= MAX_PERFORMANCE_FEE, ErrorsLib.FeeTooHigh());
        require(performanceFeeRecipient != address(0) || newPerformanceFee == 0, ErrorsLib.FeeInvariantBroken());

        accrueInterest();

        // forge-lint: disable-next-item(unsafe-typecast) safe because 2**96 > MAX_PERFORMANCE_FEE.
        performanceFee = uint96(newPerformanceFee);
        emit EventsLib.SetPerformanceFee(newPerformanceFee);
    }

    function setManagementFee(uint256 newManagementFee) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        require(newManagementFee <= MAX_MANAGEMENT_FEE, ErrorsLib.FeeTooHigh());
        require(managementFeeRecipient != address(0) || newManagementFee == 0, ErrorsLib.FeeInvariantBroken());

        accrueInterest();

        // forge-lint: disable-next-item(unsafe-typecast) safe because 2**96 > MAX_MANAGEMENT_FEE.
        managementFee = uint96(newManagementFee);
        emit EventsLib.SetManagementFee(newManagementFee);
    }

    function setPerformanceFeeRecipient(address newPerformanceFeeRecipient) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        require(newPerformanceFeeRecipient != address(0) || performanceFee == 0, ErrorsLib.FeeInvariantBroken());

        accrueInterest();

        performanceFeeRecipient = newPerformanceFeeRecipient;
        emit EventsLib.SetPerformanceFeeRecipient(newPerformanceFeeRecipient);
    }

    function setManagementFeeRecipient(address newManagementFeeRecipient) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        require(newManagementFeeRecipient != address(0) || managementFee == 0, ErrorsLib.FeeInvariantBroken());

        accrueInterest();

        managementFeeRecipient = newManagementFeeRecipient;
        emit EventsLib.SetManagementFeeRecipient(newManagementFeeRecipient);
    }

    /* ALLOCATOR FUNCTIONS */

    function allocate(address strategy, bytes memory data, uint256 assets) external {
        require(isAllocator[msg.sender], ErrorsLib.Unauthorized());
        allocateInternal(strategy, data, assets);
    }

    function allocateInternal(address strategy, bytes memory data, uint256 assets) internal {
        require(strategyManager != address(0), ErrorsLib.ZeroAddress());
        // @dev Allocate requires the strategy to be active. A curator can pause a risky strategy via
        // setStrategyActive(false) to immediately block new inflows without removing it from the registry.
        require(IStrategyManager(strategyManager).isStrategyActive(strategy), ErrorsLib.NotStrategy());

        accrueInterest();

        SafeERC20Lib.safeTransfer(asset, strategy, assets);
        (bytes32[] memory ids, int256 change) = IStrategy(strategy).allocate(data, assets, msg.sig, msg.sender);

        IStrategyManager(strategyManager).afterAllocate(strategy, ids, change, firstTotalAssets);

        emit EventsLib.Allocate(msg.sender, strategy, assets, ids, change);
    }

    function deallocate(address strategy, bytes memory data, uint256 assets) external {
        require(isAllocator[msg.sender] || _isGovernanceSentinel(msg.sender), ErrorsLib.Unauthorized());
        deallocateInternal(strategy, data, assets);
    }

    function deallocateInternal(address strategy, bytes memory data, uint256 assets)
        internal
        returns (bytes32[] memory)
    {
        require(strategyManager != address(0), ErrorsLib.ZeroAddress());
        // @dev Deallocate intentionally only checks isStrategy (not active). Once a strategy is paused via
        // setStrategyActive(false), funds must still be recoverable; otherwise pausing would trap liquidity.
        require(IStrategyManager(strategyManager).isStrategy(strategy), ErrorsLib.NotStrategy());

        (bytes32[] memory ids, int256 change) = IStrategy(strategy).deallocate(data, assets, msg.sig, msg.sender);

        IStrategyManager(strategyManager).afterDeallocate(strategy, ids, change);

        SafeERC20Lib.safeTransferFrom(asset, strategy, address(this), assets);
        emit EventsLib.Deallocate(msg.sender, strategy, assets, ids, change);
        return ids;
    }

    function setMaxRate(uint256 newMaxRate) external {
        require(msg.sender == owner, ErrorsLib.Unauthorized());
        require(newMaxRate <= MAX_MAX_RATE, ErrorsLib.MaxRateTooHigh());

        accrueInterest();

        // forge-lint: disable-next-item(unsafe-typecast) safe because newMaxRate <= MAX_MAX_RATE < 2**64-1.
        maxRate = uint64(newMaxRate);
        emit EventsLib.SetMaxRate(newMaxRate);
    }

    /* EXCHANGE RATE FUNCTIONS */

    function accrueInterest() public {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
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
        uint256 realAssets = IERC20(asset).balanceOf(address(this)).zeroFloorSub(pendingClaimableAssets);
        if (strategyManager != address(0)) realAssets += IStrategyManager(strategyManager).totalStrategyAssets();
        uint256 maxTotalAssets = _totalAssets + (_totalAssets * elapsed).mulDivDown(maxRate, WAD);
        uint256 newTotalAssets = MathLib.min(realAssets, maxTotalAssets);
        uint256 interest = newTotalAssets.zeroFloorSub(_totalAssets);

        // The performance fee assets may be rounded down to 0 if interest * fee < WAD.
        uint256 performanceFeeAssets = interest > 0 && performanceFee > 0 && canReceiveShares(performanceFeeRecipient)
            ? interest.mulDivDown(performanceFee, WAD)
            : 0;
        // The management fee is taken on newTotalAssets to make all approximations consistent (interacting less
        // increases fees).
        uint256 managementFeeAssets = elapsed > 0 && managementFee > 0 && canReceiveShares(managementFeeRecipient)
            ? (newTotalAssets * elapsed).mulDivDown(managementFee, WAD)
            : 0;

        // Interest should be accrued at least every 10 years to avoid fees exceeding total assets.
        uint256 newTotalAssetsWithoutFees = newTotalAssets - performanceFeeAssets - managementFeeAssets;
        uint256 performanceFeeShares =
            performanceFeeAssets.mulDivDown(totalSupply + virtualShares, newTotalAssetsWithoutFees + 1);
        uint256 managementFeeShares =
            managementFeeAssets.mulDivDown(totalSupply + virtualShares, newTotalAssetsWithoutFees + 1);

        return (newTotalAssets, performanceFeeShares, managementFeeShares);
    }

    /// @dev Returns previewed minted shares.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        return assets.mulDivDown(newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @dev Returns previewed deposited assets.
    function previewMint(uint256 shares) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        return shares.mulDivUp(newTotalAssets + 1, newTotalSupply + virtualShares);
    }

    /// @dev Returns previewed redeemed shares.
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        return assets.mulDivUp(newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @dev Returns previewed withdrawn assets.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply + performanceFeeShares + managementFeeShares;
        return shares.mulDivDown(newTotalAssets + 1, newTotalSupply + virtualShares);
    }

    /// @dev Returns corresponding shares (rounded down).
    /// @dev Takes into account performance and management fees.
    function convertToShares(uint256 assets) external view returns (uint256) {
        return previewDeposit(assets);
    }

    /// @dev Returns corresponding assets (rounded down).
    /// @dev Takes into account performance and management fees.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return previewRedeem(shares);
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

    /// @dev Returns minted shares.
    function deposit(uint256 assets, address onBehalf) external returns (uint256) {
        accrueInterest();
        uint256 shares = previewDeposit(assets);
        enter(assets, shares, onBehalf);
        return shares;
    }

    /// @dev Returns deposited assets.
    function mint(uint256 shares, address onBehalf) external returns (uint256) {
        accrueInterest();
        uint256 assets = previewMint(shares);
        enter(assets, shares, onBehalf);
        return assets;
    }

    /// @dev Internal function for deposit and mint.
    function enter(uint256 assets, uint256 shares, address onBehalf) internal {
        require(canReceiveShares(onBehalf), ErrorsLib.CannotReceiveShares());
        require(canSendAssets(msg.sender), ErrorsLib.CannotSendAssets());

        SafeERC20Lib.safeTransferFrom(asset, msg.sender, address(this), assets);
        createShares(onBehalf, shares);
        _totalAssets += assets.toUint128();
        emit EventsLib.Deposit(msg.sender, onBehalf, assets, shares);
    }

    /// @dev Returns redeemed shares.
    function withdraw(uint256 assets, address receiver, address onBehalf) public returns (uint256) {
        accrueInterest();
        uint256 shares = previewWithdraw(assets);
        exit(assets, shares, receiver, onBehalf);
        return shares;
    }

    /// @dev Returns withdrawn assets.
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256) {
        accrueInterest();
        uint256 assets = previewRedeem(shares);
        exit(assets, shares, receiver, onBehalf);
        return assets;
    }

    /// @dev Internal function for withdraw and redeem.
    /// @dev If idle liquidity (vault balance minus assets reserved for unclaimed withdrawal requests) covers the
    /// requested amount, assets are transferred immediately. Otherwise shares are burned now and a withdrawal request
    /// is created for the user to claim once allocator returns enough assets to the vault.
    function exit(uint256 assets, uint256 shares, address receiver, address onBehalf) internal {
        require(canSendShares(onBehalf), ErrorsLib.CannotSendShares());
        require(canReceiveAssets(receiver), ErrorsLib.CannotReceiveAssets());

        if (msg.sender != onBehalf) {
            uint256 _allowance = allowance[onBehalf][msg.sender];
            if (_allowance != type(uint256).max) allowance[onBehalf][msg.sender] = _allowance - shares;
        }

        deleteShares(onBehalf, shares);
        _totalAssets -= assets.toUint128();

        uint256 idleAssets = IERC20(asset).balanceOf(address(this));
        uint256 availableLiquidity = idleAssets.zeroFloorSub(pendingClaimableAssets);

        if (availableLiquidity >= assets) {
            SafeERC20Lib.safeTransfer(asset, receiver, assets);
            emit EventsLib.Withdraw(msg.sender, receiver, onBehalf, assets, shares);
        } else {
            uint256 requestId = nextRequestId++;
            withdrawalRequests[requestId] = WithdrawalRequest({receiver: receiver, assets: assets, claimed: false});
            pendingClaimableAssets += assets;
            emit EventsLib.WithdrawalRequested(requestId, msg.sender, receiver, onBehalf, assets, shares);
        }
    }

    /// @dev Settles a withdrawal request once enough idle liquidity is available in the vault.
    /// @dev Callable by anyone — assets are transferred to the receiver stored on the request.
    /// @dev Reverts if the request is already claimed or if idle liquidity is insufficient.
    function claim(uint256 requestId) external returns (uint256) {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        require(request.receiver != address(0), ErrorsLib.InvalidRequest());
        require(!request.claimed, ErrorsLib.RequestAlreadyClaimed());

        uint256 assets = request.assets;
        require(IERC20(asset).balanceOf(address(this)) >= assets, ErrorsLib.InsufficientLiquidity());

        request.claimed = true;
        pendingClaimableAssets -= assets;

        address receiver = request.receiver;
        SafeERC20Lib.safeTransfer(asset, receiver, assets);
        emit EventsLib.WithdrawalClaimed(requestId, receiver, assets);
        return assets;
    }

    /// @dev Returns shares withdrawn as penalty.
    /// @dev When calling this function, a penalty is taken from onBehalf, in order to discourage allocation
    /// manipulations.
    /// @dev The penalty is taken as a withdrawal for which assets are returned to the vault. In consequence,
    /// totalAssets is decreased normally along with totalSupply (the share price doesn't change except because of
    /// rounding errors), but the amount of assets actually controlled by the vault is not decreased.
    /// @dev If a user has A assets in the vault, and that the vault is already fully illiquid, the optimal amount to
    /// force deallocate in order to exit the vault is min(liquidity_of_market, A / (1 + penalty)).
    /// This ensures that either the market is empty or that it leaves no shares nor liquidity after exiting.
    function forceDeallocate(address strategy, bytes memory data, uint256 assets, address onBehalf)
        external
        returns (uint256)
    {
        bytes32[] memory ids = deallocateInternal(strategy, data, assets);
        uint256 penaltyAssets =
            assets.mulDivUp(IStrategyManager(strategyManager).forceDeallocatePenalty(strategy), WAD);
        uint256 penaltyShares = withdraw(penaltyAssets, address(this), onBehalf);
        emit EventsLib.ForceDeallocate(msg.sender, strategy, assets, onBehalf, ids, penaltyAssets);
        return penaltyShares;
    }

    function _isGovernanceSentinel(address account) internal view returns (bool) {
        if (owner.code.length == 0) return false;
        return IGovernanceTimelock(owner).isSentinel(account);
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
