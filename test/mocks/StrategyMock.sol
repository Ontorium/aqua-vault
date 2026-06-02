// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @notice Minimal strategy stub used by Vault/StrategyManager tests.
/// Tracks allocated principal plus a gain/loss overlay, and reports the *delta since the last
/// allocate/deallocate touch* as the `change` value StrategyManager uses to update cap accounting.
contract StrategyMock is IStrategy {
    address public immutable vault;
    address public immutable asset;

    /// @dev Two arbitrary ids reported by allocate/deallocate. Tests can assert on these.
    bytes32 public constant ID_0 = keccak256(bytes("id-0"));
    bytes32 public constant ID_1 = keccak256(bytes("id-1"));

    uint256 internal _principal; // cumulative allocate minus deallocate
    int256 internal _delta; // gain (>0) or loss (<0) overlay on top of principal
    uint256 internal _reportedToCaps; // last value reported back to StrategyManager via `change`

    bytes4 public recordedSelector;
    address public recordedSender;

    constructor(address _vault, address _asset) {
        vault = _vault;
        asset = _asset;
        // Pre-approve the Vault so it can pull tokens back on deallocate.
        IERC20(_asset).approve(_vault, type(uint256).max);
    }

    function setInterest(uint256 amount) external {
        _delta = int256(amount);
    }

    function setLoss(uint256 amount) external {
        _delta = -int256(amount);
    }

    function allocate(bytes calldata, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change)
    {
        require(msg.sender == vault, "only vault");
        recordedSelector = selector;
        recordedSender = sender;

        _principal += assets;
        uint256 newTotal = _currentTotalAssets();
        change = int256(newTotal) - int256(_reportedToCaps);
        _reportedToCaps = newTotal;

        ids = new bytes32[](2);
        ids[0] = ID_0;
        ids[1] = ID_1;
    }

    function deallocate(bytes calldata, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change)
    {
        require(msg.sender == vault, "only vault");
        recordedSelector = selector;
        recordedSender = sender;

        if (assets > _principal) {
            _principal = 0;
        } else {
            _principal -= assets;
        }

        uint256 newTotal = _currentTotalAssets();
        change = int256(newTotal) - int256(_reportedToCaps);
        _reportedToCaps = newTotal;

        ids = new bytes32[](2);
        ids[0] = ID_0;
        ids[1] = ID_1;
    }

    function totalAssets() external view returns (uint256) {
        return _currentTotalAssets();
    }

    function realAssets() external view returns (uint256) {
        return _currentTotalAssets();
    }

    function availableLiquidity() external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function _currentTotalAssets() internal view returns (uint256) {
        int256 v = int256(_principal) + _delta;
        return v < 0 ? 0 : uint256(v);
    }
}
