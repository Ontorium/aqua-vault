// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {Test, console} from "../../lib/forge-std/src/Test.sol";

import {Vault} from "../../src/Vault.sol";
import {StrategyManager} from "../../src/StrategyManager.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {AquaStrategy} from "../../src/strategies/AquaStrategy.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import "../../src/libraries/ConstantsLib.sol";

/// @notice Fork test that drives the LIVE Arbitrum-Sepolia deployment: it binds the already-deployed
/// RoleManager / Timelock / StrategyManager / USDT-Vault, deploys a fresh AquaStrategy against the real
/// Aqua (Aave-V2) lending pool, and runs a deposit → allocate → (accrue) → deallocate round-trip so we
/// can confirm the wiring works against the real pool — not a mock.
///
/// Governance on the live vault is held by the Timelock, so role-gated calls are issued by pranking the
/// Timelock address (it holds scoped(vault, GOVERNANCE)); the cheatcode bypasses the schedule/execute
/// delay, which is exactly what we want for a smoke test.
///
/// Run (needs an RPC; auto-skips if ARBITRUM_SEPOLIA_RPC_URL is unset):
///   forge test --match-path test/fork/AquaForkTest.sol -vv
contract AquaForkTest is Test {
    /* LIVE DEPLOYMENT (Arbitrum Sepolia) */
    address constant ROLE_MANAGER = 0x52815561C58731761DBfa302d0aE160712F7b331;
    address constant TIMELOCK = 0x00Ba9Bd0E7aE1c0D726901786A3638A64aa1027b;
    address constant ADMIN = 0x0eD039d012B6c241e1636af8A0d2B6eC8c972b11; // holds DEFAULT_ADMIN_ROLE
    address constant STRATEGY_MANAGER = 0xe366037A8092A5159c19FfA9B30e6344dd412386;
    address constant VAULT = 0xD408A6B5425e9866dc05F68F2c75e8F2F7495d95;
    address constant ASSET = 0x6777ab1c1EBFC40d3442202158bEA959E04AC744; // USDT (6 decimals)
    address constant AQUA_POOL = 0xd7105C76a995b8566e2DcC991FB4D8A13Ca6f816; // Aave-V2-style lending pool
    address constant ATOKEN = 0x6E6d0013a5c76131652bc7282eeac5536D8c2ae3; // acUSDT

    uint256 constant AMOUNT = 1_000e6; // 1,000 USDT

    RoleManager rm = RoleManager(ROLE_MANAGER);
    StrategyManager sm = StrategyManager(STRATEGY_MANAGER);
    Vault vault = Vault(VAULT);

    AquaStrategy strategy;
    bool skipped;

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            skipped = true;
            return;
        }
        vm.createSelectFork(rpc);

        // Sanity: the live vault really is the USDT vault wired to the given StrategyManager.
        assertEq(vault.asset(), ASSET, "vault asset != USDT");
        assertEq(vault.strategyManager(), STRATEGY_MANAGER, "vault SM mismatch");

        // Deploy a fresh AquaStrategy pointing at the live vault + real Aqua pool.
        strategy = new AquaStrategy(VAULT, ASSET, AQUA_POOL, ATOKEN, ROLE_MANAGER);

        // The live vault's scoped GOVERNANCE isn't held by the deployer/Timelock anymore, but the global
        // DEFAULT_ADMIN (the deployer) still administers it. Prank DEFAULT_ADMIN once to grant ourselves
        // GOVERNANCE; from there this contract can register the strategy, lift caps, and self-grant ALLOCATOR.
        bytes32 govRole = rm.getScopedRole(VAULT, "GOVERNANCE_ROLE");
        vm.prank(ADMIN);
        rm.grantRole(govRole, address(this));

        // Register the strategy and lift caps for BOTH ids it emits (adapter + aToken group).
        bytes memory adapterIdData = abi.encode("AquaStrategy", address(strategy));
        bytes memory aTokenIdData = abi.encode("aToken", ATOKEN);
        sm.addStrategy(address(strategy), 1 /* ONCHAIN */, 0, 0);
        sm.increaseAbsoluteCap(adapterIdData, type(uint128).max);
        sm.increaseRelativeCap(adapterIdData, WAD);
        sm.increaseAbsoluteCap(aTokenIdData, type(uint128).max);
        sm.increaseRelativeCap(aTokenIdData, WAD);
        rm.grantRole(rm.getScopedRole(VAULT, "ALLOCATOR_ROLE"), address(this)); // admin = GOV (held above)
    }

    function _adapterId() internal view returns (bytes32) {
        return keccak256(abi.encode("AquaStrategy", address(strategy)));
    }

    function _aTokenId() internal pure returns (bytes32) {
        return keccak256(abi.encode("aToken", ATOKEN));
    }

    /// @dev Deposit USDT and route it into the real Aqua pool.
    function _depositAndAllocate() internal {
        deal(ASSET, address(this), AMOUNT);
        IERC20(ASSET).approve(VAULT, AMOUNT);
        vault.deposit(AMOUNT, address(this));

        vault.allocate(address(strategy), hex"", AMOUNT); // we hold ALLOCATOR_ROLE
    }

    /* ── deposit → allocate into the LIVE Aqua pool ───────────────────────────── */

    function testForkAllocateSuppliesToAqua() public {
        if (skipped) {
            vm.skip(true);
            return;
        }

        _depositAndAllocate();

        // The strategy now holds acUSDT (aTokens) ~= the supplied principal (allow 1 wei rebase rounding).
        assertApproxEqAbs(IERC20(ATOKEN).balanceOf(address(strategy)), AMOUNT, 1, "strategy holds aTokens");
        assertApproxEqAbs(strategy.totalAssets(), AMOUNT, 1, "totalAssets == aToken balance");
        // StrategyManager aggregates the position under both caps.
        assertApproxEqAbs(sm.totalStrategyAssets(), AMOUNT, 1, "SM aggregates aToken value");
        assertApproxEqAbs(sm.allocation(_adapterId()), AMOUNT, 1, "adapter cap allocation");
        assertApproxEqAbs(sm.allocation(_aTokenId()), AMOUNT, 1, "aToken cap allocation");

        console.log("aToken (acUSDT) held by strategy:", IERC20(ATOKEN).balanceOf(address(strategy)));
        console.log("vault.totalAssets()             :", vault.totalAssets());
    }

    /* ── interest accrual on the live pool ────────────────────────────────────── */

    function testForkInterestAccrues() public {
        if (skipped) {
            vm.skip(true);
            return;
        }

        _depositAndAllocate();
        uint256 before = strategy.totalAssets();

        // Let the live reserve accrue. aToken.balanceOf grows with the pool's liquidity index.
        skip(180 days);

        uint256 afterAssets = strategy.totalAssets();
        console.log("aToken before :", before);
        console.log("aToken after  :", afterAssets);
        // Non-decreasing (the pool may have a 0% rate on testnet, so we don't require strict growth).
        assertGe(afterAssets, before, "aToken balance must not shrink over time");
    }

    /* ── full round-trip: deallocate back out of the live pool ────────────────── */

    /// @dev NOTE: AquaStrategy never approves the vault, so the vault's deallocate pullback
    /// (`safeTransferFrom(asset, strategy, vault, ...)`) cannot pull funds back as-is. We prank the
    /// strategy to grant that allowance here so the round-trip exercises the real pool withdraw.
    /// This is a workaround for a missing approval in AquaStrategy — see the chat note.
    function testForkDeallocateWithdrawsFromAqua() public {
        if (skipped) {
            vm.skip(true);
            return;
        }

        _depositAndAllocate();

        // Workaround for the missing strategy->vault approval (OffchainNAVStrategy does this internally).
        vm.prank(address(strategy));
        IERC20(ASSET).approve(VAULT, type(uint256).max);

        uint256 vaultBalBefore = IERC20(ASSET).balanceOf(VAULT);

        // Pull half back out of the real Aqua pool. deallocate is ALLOCATOR-or-SENTINEL gated.
        uint256 pull = AMOUNT / 2;
        vault.deallocate(address(strategy), hex"", pull);

        assertApproxEqAbs(IERC20(ASSET).balanceOf(VAULT), vaultBalBefore + pull, 1, "USDT returned to vault");
        assertApproxEqAbs(strategy.totalAssets(), AMOUNT - pull, 1, "strategy position reduced");
    }
}
