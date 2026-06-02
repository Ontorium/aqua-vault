// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import "./BaseTest.sol";
import {MorphoStrategy} from "../src/strategies/MorphoStrategy.sol";
import {MarketParams, Id} from "../src/strategies/morpho/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../src/strategies/morpho/libraries/MarketParamsLib.sol";
import {MorphoMock} from "./mocks/MorphoMock.sol";
import {IrmMock} from "./mocks/IrmMock.sol";

/// @notice Covers MorphoStrategy against a minimal Morpho mock: allocate/deallocate accounting, IRM
/// whitelist gating, share-price inflation defense, emergency `burnShares` write-off, multi-tier `ids[]`
/// for vault-level caps, and `skim` token recovery.
contract MorphoStrategyTest is BaseTest {
    using MarketParamsLib for MarketParams;

    MorphoStrategy internal strategy;
    MorphoMock internal morpho;
    IrmMock internal irm;
    IrmMock internal otherIrm;

    address internal collateralA = makeAddr("WBTC");
    address internal collateralB = makeAddr("WETH");

    function setUp() public override {
        super.setUp();
        morpho = new MorphoMock();
        irm = new IrmMock();
        otherIrm = new IrmMock();

        strategy = new MorphoStrategy(
            address(vault), address(underlyingToken), address(morpho), address(roleManager)
        );

        // Whitelist the canonical IRM. Tests that exercise rejection use `otherIrm`.
        vm.prank(governance);
        strategy.setIrmApproved(address(irm), true);
    }

    /* ── helpers ──────────────────────────────────────────────────────────────── */

    function _params(address collateral, address useIrm) internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(underlyingToken),
            collateralToken: collateral,
            oracle: address(0),
            irm: useIrm,
            lltv: 0.86e18
        });
    }

    function _fundAndAllocate(MarketParams memory mp, uint256 amount) internal returns (bytes32[] memory ids, int256 change) {
        underlyingToken.mint(address(strategy), amount);
        vm.prank(address(vault));
        (ids, change) = strategy.allocate(abi.encode(mp), amount, bytes4(0), address(0));
    }

    function _expectedAdapterId() internal view returns (bytes32) {
        return keccak256(abi.encode("MorphoStrategy", address(strategy)));
    }

    function _expectedCollateralId(address collateral) internal pure returns (bytes32) {
        return keccak256(abi.encode("collateralToken", collateral));
    }

    function _expectedMarketId(MarketParams memory mp) internal view returns (bytes32) {
        return keccak256(abi.encode(address(strategy), Id.unwrap(mp.id())));
    }

    /* ── CONSTRUCTOR / WIRING ─────────────────────────────────────────────────── */

    function testConstructorWiresAndApproves() public view {
        assertEq(strategy.vault(), address(vault));
        assertEq(strategy.asset(), address(underlyingToken));
        assertEq(address(strategy.morpho()), address(morpho));
        assertEq(underlyingToken.allowance(address(strategy), address(morpho)), type(uint256).max);
    }

    /* ── ALLOCATE ─────────────────────────────────────────────────────────────── */

    function testAllocateSuppliesToMorpho(uint256 amount) public {
        amount = bound(amount, 1e6, 1e30);
        MarketParams memory mp = _params(collateralA, address(irm));

        (bytes32[] memory ids, int256 change) = _fundAndAllocate(mp, amount);

        assertEq(underlyingToken.balanceOf(address(morpho)), amount, "morpho received underlying");
        assertEq(underlyingToken.balanceOf(address(strategy)), 0, "strategy drained");
        // First-supply share math has virtual-share offset; allow a tiny rounding band.
        assertApproxEqAbs(strategy.totalAssets(), amount, 1, "totalAssets ~= supplied");
        assertEq(change, int256(strategy.totalAssets()), "change matches");
        assertEq(ids.length, 3, "3-tier ids");
        assertEq(ids[0], _expectedAdapterId(), "adapter id");
        assertEq(ids[1], _expectedCollateralId(collateralA), "collateral id");
        assertEq(ids[2], _expectedMarketId(mp), "market id");
    }

    function testAllocateRejectsUnapprovedIrm() public {
        MarketParams memory mp = _params(collateralA, address(otherIrm));
        underlyingToken.mint(address(strategy), 100e18);

        vm.prank(address(vault));
        vm.expectRevert(MorphoStrategy.IrmNotApproved.selector);
        strategy.allocate(abi.encode(mp), 100e18, bytes4(0), address(0));
    }

    function testAllocateRejectsLoanTokenMismatch() public {
        MarketParams memory mp = _params(collateralA, address(irm));
        mp.loanToken = makeAddr("OTHER_TOKEN");
        underlyingToken.mint(address(strategy), 100e18);

        vm.prank(address(vault));
        vm.expectRevert(MorphoStrategy.LoanAssetMismatch.selector);
        strategy.allocate(abi.encode(mp), 100e18, bytes4(0), address(0));
    }

    function testAllocateOnlyVault(address rdm) public {
        vm.assume(rdm != address(vault));
        MarketParams memory mp = _params(collateralA, address(irm));
        underlyingToken.mint(address(strategy), 100e18);

        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        strategy.allocate(abi.encode(mp), 100e18, bytes4(0), address(0));
    }

    /* ── DEALLOCATE ───────────────────────────────────────────────────────────── */

    function testDeallocateWithdrawsFromMorpho() public {
        MarketParams memory mp = _params(collateralA, address(irm));
        _fundAndAllocate(mp, 1000e18);

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = strategy.deallocate(abi.encode(mp), 400e18, bytes4(0), address(0));

        assertEq(underlyingToken.balanceOf(address(strategy)), 400e18, "underlying returned");
        assertApproxEqAbs(strategy.totalAssets(), 600e18, 1, "remaining position");
        assertEq(ids.length, 3, "3-tier ids");
        assertLt(change, 0, "negative change");
    }

    /// @notice Even when the market's IRM has been un-approved, deallocate must still work so the vault
    /// can exit a broken position. Only allocate is gated by the whitelist.
    function testDeallocateWorksEvenWithUnapprovedIrm() public {
        MarketParams memory mp = _params(collateralA, address(irm));
        _fundAndAllocate(mp, 500e18);

        // Governance later un-approves the IRM (e.g., security incident).
        vm.prank(governance);
        strategy.setIrmApproved(address(irm), false);

        // Deallocate still proceeds.
        vm.prank(address(vault));
        strategy.deallocate(abi.encode(mp), 500e18, bytes4(0), address(0));
        assertEq(underlyingToken.balanceOf(address(strategy)), 500e18);
    }

    /* ── INTEREST ─────────────────────────────────────────────────────────────── */

    function testTotalAssetsReflectsSimulatedInterest() public {
        MarketParams memory mp = _params(collateralA, address(irm));
        _fundAndAllocate(mp, 1000e18);

        uint256 before = strategy.totalAssets();
        morpho.simulateInterest(mp.id(), 100e18);

        // Our share is the only supply → all 100e18 of interest accrues to us.
        assertApproxEqAbs(strategy.totalAssets(), before + 100e18, 1, "interest surfaced in NAV");
    }

    function testAvailableLiquidityCapsAtMarketLiquidity() public {
        MarketParams memory mp = _params(collateralA, address(irm));
        _fundAndAllocate(mp, 1000e18);

        // Simulate 700 borrowed out → market free liquidity = 300.
        morpho.simulateBorrow(mp.id(), 700e18);

        assertApproxEqAbs(strategy.totalAssets(), 1000e18, 1, "totalAssets unchanged");
        assertEq(strategy.availableLiquidity(), 300e18, "available capped at market free");
    }

    /* ── MULTI-MARKET ─────────────────────────────────────────────────────────── */

    function testTotalAssetsSumsAcrossMultipleMarkets() public {
        MarketParams memory mpA = _params(collateralA, address(irm));
        MarketParams memory mpB = _params(collateralB, address(irm));

        _fundAndAllocate(mpA, 700e18);
        _fundAndAllocate(mpB, 300e18);

        assertEq(strategy.marketIdsLength(), 2, "two markets tracked");
        assertApproxEqAbs(strategy.totalAssets(), 1000e18, 2, "sum across markets");
    }

    /* ── IDS (multi-tier caps) ────────────────────────────────────────────────── */

    function testIdsExposeAllThreeTiers() public {
        MarketParams memory mp = _params(collateralA, address(irm));
        (bytes32[] memory ids,) = _fundAndAllocate(mp, 100e18);
        assertEq(ids.length, 3);
        assertEq(ids[0], _expectedAdapterId(), "[0] = adapter");
        assertEq(ids[1], _expectedCollateralId(collateralA), "[1] = collateral");
        assertEq(ids[2], _expectedMarketId(mp), "[2] = market");
    }

    /* ── BURN SHARES (emergency write-off) ────────────────────────────────────── */

    function testBurnSharesZeroesMarketContribution() public {
        MarketParams memory mp = _params(collateralA, address(irm));
        _fundAndAllocate(mp, 1000e18);
        assertGt(strategy.totalAssets(), 0);
        assertEq(strategy.marketIdsLength(), 1);

        vm.prank(governance);
        strategy.burnShares(mp.id());

        assertEq(strategy.totalAssets(), 0, "market dropped from NAV");
        assertEq(strategy.marketIdsLength(), 0, "removed from active list");
        // Shares on Morpho's side remain (lost forever).
        assertGt(morpho.position(mp.id(), address(strategy)).supplyShares, 0, "shares stranded on Morpho");
    }

    function testBurnSharesNoopWhenNothingToWriteOff() public {
        MarketParams memory mp = _params(collateralA, address(irm));
        vm.prank(governance);
        strategy.burnShares(mp.id()); // No emit, no revert.
    }

    function testBurnSharesOnlyGovernance(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));
        MarketParams memory mp = _params(collateralA, address(irm));
        _fundAndAllocate(mp, 100e18);

        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        strategy.burnShares(mp.id());
    }

    /* ── IRM WHITELIST ────────────────────────────────────────────────────────── */

    function testSetIrmApprovedOnlyGovernance(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));
        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        strategy.setIrmApproved(address(otherIrm), true);
    }

    function testSetIrmApprovedRejectsZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        strategy.setIrmApproved(address(0), true);
    }

    function testApprovingAndRevokingIrm() public {
        assertFalse(strategy.irmApproved(address(otherIrm)));

        vm.prank(governance);
        strategy.setIrmApproved(address(otherIrm), true);
        assertTrue(strategy.irmApproved(address(otherIrm)));

        vm.prank(governance);
        strategy.setIrmApproved(address(otherIrm), false);
        assertFalse(strategy.irmApproved(address(otherIrm)));
    }

    /* ── SUPPLY SHARES GETTER ─────────────────────────────────────────────────── */

    function testSupplySharesDelegatesToMorpho() public {
        MarketParams memory mp = _params(collateralA, address(irm));
        _fundAndAllocate(mp, 1000e18);

        uint256 fromMorpho = morpho.position(mp.id(), address(strategy)).supplyShares;
        assertEq(strategy.supplyShares(mp.id()), fromMorpho, "delegates to morpho.position");
    }

    /* ── SKIM ─────────────────────────────────────────────────────────────────── */

    function testSkimRecoversNonProtectedToken() public {
        address recipient = makeAddr("skimRecipient");
        ERC20Mock rewardToken = new ERC20Mock(18);
        rewardToken.mint(address(strategy), 500e18);

        vm.prank(governance);
        strategy.setSkimRecipient(recipient);
        vm.prank(recipient);
        strategy.skim(address(rewardToken));

        assertEq(rewardToken.balanceOf(recipient), 500e18);
    }

    function testSkimRevertsOnUnderlying() public {
        address recipient = makeAddr("skimRecipient");
        vm.prank(governance);
        strategy.setSkimRecipient(recipient);

        underlyingToken.mint(address(strategy), 100e18);
        vm.prank(recipient);
        vm.expectRevert(MorphoStrategy.CannotSkimUnderlying.selector);
        strategy.skim(address(underlyingToken));
    }

    function testSkimRevertsWhenRecipientUnset() public {
        ERC20Mock rewardToken = new ERC20Mock(18);
        rewardToken.mint(address(strategy), 100e18);
        vm.expectRevert(MorphoStrategy.SkimRecipientUnset.selector);
        strategy.skim(address(rewardToken));
    }

    function testSetSkimRecipientOnlyGovernance(address rdm) public {
        vm.assume(rdm != governance && rdm != address(timelock));
        vm.prank(rdm);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        strategy.setSkimRecipient(makeAddr("anyone"));
    }
}
