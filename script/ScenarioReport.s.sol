// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../lib/forge-std/src/Script.sol";
import {VmSafe} from "../lib/forge-std/src/Vm.sol";
import {StdCheats} from "../lib/forge-std/src/StdCheats.sol";
import {EnvSigner} from "./EnvSigner.sol";

import {Vault} from "../src/Vault.sol";
import {StrategyManager} from "../src/StrategyManager.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {AquaStrategy} from "../src/strategies/AquaStrategy.sol";
import {OffchainNAVStrategy} from "../src/strategies/OffchainNAVStrategy.sol";
import {WAD} from "../src/libraries/ConstantsLib.sol";

interface IERC20Detailed {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IAquaPool {
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);
}

/// @notice End-to-end scenario report — drives the LIVE deployment through Vault entry/exit calls
/// AND a roundtrip into the real Aqua (Aave-V2) lending pool, recording vault / strategy / pool
/// state at every step. Emits ONE markdown report covering vault scenarios (deposit/mint/withdraw/
/// redeem/pause) plus the Aqua-specific path (allocate/accrue/deallocate, optional time skip).
///
/// Required env: PRIVATE_KEY or MNEMONIC, VAULT, STRATEGY_MANAGER, ROLE_MANAGER.
///
/// Strategy resolution (no extra env in the common case):
///   1) If a strategy with an `aToken()` getter is registered on the StrategyManager, the script
///      picks the first match — that's the AquaStrategy for this vault.
///   2) Otherwise (FORK MODE ONLY): the script deploys a fresh AquaStrategy on the fork and wires
///      it through the SM. Requires ATOKEN env (acUSDT for USDT vault, acAGT for OXAU vault).
///      AQUA_POOL defaults to 0xd7105C76a995b8566e2DcC991FB4D8A13Ca6f816 (override if needed).
///   3) `AQUA_STRATEGY` env still works as an explicit override.
///
/// Optional env:
///   SCENARIOS — comma-separated subset (default = all). Names match the section ids below.
///
/// Test amounts (deposit/mint/allocate/etc.) are intentionally NOT env-configurable. They're
/// fixed inside the script (see _depositAmount / _mintShares / _allocateAmount / ...) so the
/// report is reproducible across runs and immune to stale `.env` values.
///
/// Modes:
///   fork:  forge script script/ScenarioReport.s.sol --rpc-url arbitrum_sepolia --skip-simulation
///          → forks the chain; if no AquaStrategy is registered, deploys + wires one on the fork;
///            funds the user with USDT via `deal`; writes reports/scenario-fork.md
///   live:  forge script script/ScenarioReport.s.sol --rpc-url arbitrum_sepolia --broadcast
///          → writes reports/_scenario_header.md + reports/_scenario_body.md
///          forge script script/BuildReport.s.sol --sig "buildScenario()"
///          → writes reports/scenario-arbitrum-sepolia.md (tx hashes patched in)
contract ScenarioReport is EnvSigner, StdCheats {
    Vault internal vault;
    StrategyManager internal sm;
    RoleManager internal rm;
    AquaStrategy internal strategy;
    OffchainNAVStrategy internal offchain;
    IERC20Detailed internal asset;
    IERC20Detailed internal aToken;
    IAquaPool internal pool;

    /* Four actors derived from MNEMONIC at indices 0/1/2/3.
     * - deployer (0): DEFAULT_ADMIN — bootstrap only, distributes operational roles to operator
     * - user     (1): vault depositor — runs deposit/mint/withdraw/redeem/claim
     * - operator (2): GOV + ALLOCATOR + SENTINEL + OFFCHAIN_MANAGER + OFFCHAIN_REPORTER —
     *                 day-to-day operational role (allocate/deallocate/report/pause/etc.)
     *                 Index 2 (most ETH-funded on our testnet wallets) handles the busiest role.
     * - custodian(3): offchain entity — receives capital, returns it (only 1 broadcast tx)
     * Single-account fallback (PRIVATE_KEY only): all four collapse to the same signer.
     */
    address internal deployer;
    address internal user;
    address internal custodian;
    address internal operator;
    uint256 internal deployerPk;
    uint256 internal userPk;
    uint256 internal custodianPk;
    uint256 internal operatorPk;

    bool internal live;
    uint256 internal caseNo;
    string internal body;

    struct Snap {
        // Vault
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 sharePrice;
        uint256 userShares;
        uint256 userAsset;
        uint256 vaultAsset;
        uint256 userPendingAssets; // user's queued withdrawal awaiting fulfillment
        uint256 userClaimableAssets; // user's fulfilled withdrawal awaiting claim()
        // AquaStrategy
        uint256 strategyAssets;
        uint256 strategyATokenBal;
        uint256 strategyWrittenOff;
        // Aqua pool
        uint256 poolLiquidity;
        uint256 poolATokenSupply;
        uint256 poolImpliedDebt;
        uint256 normalizedIncome;
        uint256 normalizedDebt;
        // OffchainNAVStrategy
        uint256 offTotalAssets;
        uint256 offIdle;
        uint256 offReportedAssets;
        uint256 offReportedAvailableLiquidity;
        uint256 offPendingReceivable;
        uint256 custodianBal;
        bool offStrictMode;
        bool offIsStale;
    }

    function run() external {
        vault = Vault(vm.envAddress("VAULT"));
        sm = StrategyManager(vm.envAddress("STRATEGY_MANAGER"));
        rm = RoleManager(vm.envAddress("ROLE_MANAGER"));
        asset = IERC20Detailed(vault.asset());

        live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);

        // Derive the three actors. If MNEMONIC is set, use indices 0/1/2; otherwise fall back to
        // PRIVATE_KEY and collapse all three roles onto the single signer.
        _deriveActors();

        // Start broadcasting as the deployer (admin). Subsequent test cases switch actors as needed.
        _asDeployer();

        // AquaStrategy resolution.
        address foundAqua = vm.envOr("AQUA_STRATEGY", address(0));
        if (foundAqua == address(0)) foundAqua = _findRegisteredAquaStrategy();
        if (foundAqua != address(0)) {
            strategy = AquaStrategy(foundAqua);
            console.log("Using AquaStrategy:", foundAqua);
        } else {
            require(
                !live,
                "No AquaStrategy registered on this StrategyManager. Run step 09 first, or set AQUA_STRATEGY."
            );
            _deployAndWireStrategy();
        }
        aToken = IERC20Detailed(strategy.aToken());
        pool = IAquaPool(strategy.lendingPool());

        // OffchainNAVStrategy resolution (optional but auto-deployed in fork mode).
        address foundOffchain = vm.envOr("OFFCHAIN_STRATEGY", address(0));
        if (foundOffchain == address(0)) foundOffchain = _findRegisteredOffchainStrategy();
        if (foundOffchain != address(0)) {
            offchain = OffchainNAVStrategy(foundOffchain);
            console.log("Using OffchainNAVStrategy:", foundOffchain);
        } else if (!live) {
            _deployAndWireOffchain();
        }

        _bootstrap();

        // Order: Vault entry → Aqua roundtrip → Offchain roundtrip → Vault exit → emergency.
        // Each case switches to the appropriate actor at its boundary.
        if (_enabled("deposit_to_vault"))         { _asUser();     _case_deposit(); }
        if (_enabled("mint_to_vault"))            { _asUser();     _case_mint(); }
        if (_enabled("allocate_to_aqua"))         { _asOperator(); _case_allocate(); }
        if (!live && _enabled("time_skip"))       {                _case_skipTime(); }
        if (_enabled("deallocate_from_aqua"))     { _asOperator(); _case_deallocate(); }
        if (_enabled("allocate_to_offchain"))     { _asOperator(); _case_offchainAllocate(); }
        if (_enabled("deploy_to_custodian"))      { _asOperator(); _case_deployToCustodian(); }
        if (_enabled("nav_report_gain"))          { _asOperator(); _case_navReport(); }
        if (_enabled("return_from_custodian"))    {                _case_returnFromCustodian(); }
        if (_enabled("deallocate_from_offchain")) { _asOperator(); _case_offchainDeallocate(); }
        if (_enabled("withdraw_immediate"))       { _asUser();     _case_withdrawImmediate(); }
        if (_enabled("withdraw_queued"))          { _asUser();     _case_withdrawQueued(); }
        if (_enabled("redeem_with_yield"))        { _asUser();     _case_redeem(); }
        if (_enabled("claim_queued_withdrawal"))  { _asOperator(); _case_claim(); }
        if (_enabled("multi_user_claim_isolation")) { _asDeployer(); _case_multiUserClaimIsolation(); }
        if (_enabled("pause_unpause"))            { _asOperator(); _case_pause(); }

        vm.stopBroadcast();
        _write();
    }

    /* ───────────────────────── ACTOR DERIVATION + SWITCHING ───────────────────────── */

    /// @dev Derives deployer/user/custodian PKs+addresses from MNEMONIC at indices 0/1/2. If
    /// MNEMONIC is unset, falls back to PRIVATE_KEY (single-account mode — all three roles share
    /// the signer). Live mode requires PKs (the script broadcasts as each actor).
    function _deriveActors() internal {
        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            deployerPk  = vm.deriveKey(mnemonic, uint32(vm.envOr("DEPLOYER_INDEX",  uint256(0))));
            userPk      = vm.deriveKey(mnemonic, uint32(vm.envOr("USER_INDEX",      uint256(1))));
            operatorPk  = vm.deriveKey(mnemonic, uint32(vm.envOr("OPERATOR_INDEX",  uint256(2))));
            custodianPk = vm.deriveKey(mnemonic, uint32(vm.envOr("CUSTODIAN_INDEX", uint256(3))));
        } else {
            // Single-account fallback. PRIVATE_KEY drives all four.
            uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
            require(pk != 0, "Set MNEMONIC (multi-account) or PRIVATE_KEY (single-account)");
            deployerPk = pk;
            userPk = pk;
            custodianPk = pk;
            operatorPk = pk;
        }
        deployer  = vm.addr(deployerPk);
        user      = vm.addr(userPk);
        custodian = vm.addr(custodianPk);
        operator  = vm.addr(operatorPk);
        console.log("Deployer :", deployer);
        console.log("User     :", user);
        console.log("Custodian:", custodian);
        console.log("Operator :", operator);
    }

    address internal _currentActor;

    /// @dev Switch the active broadcaster. No-op if already the current actor (avoids redundant
    /// stop/start cycles). Each switch ends the current broadcast and starts a new one keyed by the
    /// target actor's private key.
    function _switchTo(uint256 pk, address actor) internal {
        if (_currentActor == actor) return;
        if (_currentActor != address(0)) vm.stopBroadcast();
        vm.startBroadcast(pk);
        _currentActor = actor;
    }

    function _asDeployer()  internal { _switchTo(deployerPk,  deployer); }
    function _asUser()      internal { _switchTo(userPk,      user); }
    function _asCustodian() internal { _switchTo(custodianPk, custodian); }
    function _asOperator()  internal { _switchTo(operatorPk,  operator); }

    /* ───────────────────────────── BOOTSTRAP ───────────────────────────── */

    /// @dev Scans every registered strategy and returns the first one with an `aToken()` getter —
    /// the AquaStrategy fingerprint (Morpho/Offchain strategies don't have it).
    function _findRegisteredAquaStrategy() internal view returns (address) {
        uint256 len = sm.strategiesLength();
        for (uint256 i; i < len; i++) {
            address strategy = sm.strategies(i);
            try AquaStrategy(strategy).aToken() returns (address) {
                return strategy;
            } catch {}
        }
        return address(0);
    }

    /// @dev OffchainNAVStrategy fingerprint: only this strategy exposes `custodian()` (Aqua/Morpho don't).
    function _findRegisteredOffchainStrategy() internal view returns (address) {
        uint256 len = sm.strategiesLength();
        for (uint256 i; i < len; i++) {
            address strategy = sm.strategies(i);
            try OffchainNAVStrategy(strategy).custodian() returns (address) {
                return strategy;
            } catch {}
        }
        return address(0);
    }

    /// @dev Fork-only: deploys an OffchainNAVStrategy with the signer as custodian for simulation.
    /// Default knobs: stalePeriod 7 days, maxChangeBps 1000 (10%).
    function _deployAndWireOffchain() internal {
        offchain = new OffchainNAVStrategy(
            address(vault), address(asset), address(rm), custodian, 7 days, 1000
        );

        bytes32 gov = rm.getScopedRole(address(vault), "GOVERNANCE_ROLE");
        if (!rm.hasRole(gov, deployer)) rm.grantRole(gov, deployer);

        sm.addStrategy(address(offchain), 1 /* ONCHAIN */, 0);
        bytes32 strategyIdHash = offchain.strategyId();
        bytes memory idData = abi.encode(address(offchain), address(asset));
        // strategyId is keccak256(abi.encode(address(this), asset)); idData matches.
        require(keccak256(idData) == strategyIdHash, "strategyId encoding mismatch");
        sm.increaseAbsoluteCap(idData, type(uint128).max);
        sm.increaseRelativeCap(idData, WAD);

        console.log("[fork] Deployed + wired OffchainNAVStrategy at:", address(offchain));
    }

    /// @dev Fork-only fallback when no strategy is registered yet — mirrors step 09's wiring.
    function _deployAndWireStrategy() internal {
        address aTokenAddr = vm.envAddress("ATOKEN");
        address poolAddr = vm.envOr("AQUA_POOL", address(0xd7105C76a995b8566e2DcC991FB4D8A13Ca6f816));

        strategy = new AquaStrategy(address(vault), address(asset), poolAddr, aTokenAddr, address(rm));

        bytes32 gov = rm.getScopedRole(address(vault), "GOVERNANCE_ROLE");
        if (!rm.hasRole(gov, deployer)) rm.grantRole(gov, deployer);

        sm.addStrategy(address(strategy), 1, 0);
        bytes memory strategyIdData = abi.encode("AquaStrategy", address(strategy));
        bytes memory aTokenIdData = abi.encode("aToken", aTokenAddr);
        sm.increaseAbsoluteCap(strategyIdData, type(uint128).max);
        sm.increaseRelativeCap(strategyIdData, WAD);
        sm.increaseAbsoluteCap(aTokenIdData, type(uint128).max);
        sm.increaseRelativeCap(aTokenIdData, WAD);

        console.log("[fork] Deployed + wired AquaStrategy at:", address(strategy));
    }

    function _bootstrap() internal {
        // (1) Deployer (DEFAULT_ADMIN) grants ALL operational roles to operator (account 3).
        _asDeployer();

        bytes32 gov = rm.getScopedRole(address(vault), "GOVERNANCE_ROLE");
        bytes32 alloc = rm.getScopedRole(address(vault), "ALLOCATOR_ROLE");
        bytes32 sentinel = rm.getScopedRole(address(vault), "SENTINEL_ROLE");
        if (!rm.hasRole(gov, operator))      rm.grantRole(gov, operator);
        if (!rm.hasRole(alloc, operator))    rm.grantRole(alloc, operator);
        if (!rm.hasRole(sentinel, operator)) rm.grantRole(sentinel, operator);

        if (address(offchain) != address(0)) {
            bytes32 mgr = rm.getScopedRole(address(offchain), "OFFCHAIN_MANAGER");
            bytes32 rpt = rm.getScopedRole(address(offchain), "OFFCHAIN_REPORTER");
            if (!rm.hasRole(mgr, operator)) rm.grantRole(mgr, operator);
            if (!rm.hasRole(rpt, operator)) rm.grantRole(rpt, operator);
        }

        // (2) Operator runs config operations (GOVERNANCE-gated).
        _asOperator();

        if (address(offchain) != address(0)) {
            if (offchain.custodian() != custodian) {
                offchain.setCustodian(custodian);
                console.log("[setup] strategy.setCustodian ->", custodian);
            }
            if (offchain.maxChangeBps() < 10_000) {
                offchain.setMaxChangeBps(10_000);
                console.log("[setup] offchain.maxChangeBps = 10000 (no cap)");
            }
        }
        if (vault.maxRate() == 0) {
            vault.setMaxRate(WAD / 365 days); // 100% APR cap
            console.log("[setup] vault.maxRate = 100% APR");
        }

        // (3) Fork mode: provision USDT for user, ETH for custodian/operator, patch strategy
        // allowance if needed. Live mode requires pre-funded testnet accounts.
        if (!live) {
            uint256 needed = _depositAmount() * 5;
            if (asset.balanceOf(user) < needed) {
                deal(address(asset), user, needed);
                console.log("[fork] deal USDT to user:", needed);
            }
            if (custodian.balance < 0.1 ether) { vm.deal(custodian, 1 ether); console.log("[fork] deal ETH to custodian"); }
            if (operator.balance  < 0.1 ether) { vm.deal(operator,  1 ether); console.log("[fork] deal ETH to operator"); }
        }

        // (4) User approves the vault to pull USDT for deposit/mint.
        _asUser();
        asset.approve(address(vault), type(uint256).max);
    }

    /* ──────────────── TEST AMOUNTS (script-internal, no env) ──────────────── */

    /// @dev Deposit ~1 asset unit (e.g. 1 USDT for a 6-decimal asset). Picks a natural human-readable
    /// scale that's safely below most strategy/aToken caps on testnet pools.
    function _depositAmount() internal view returns (uint256) {
        return uint256(10) ** uint256(asset.decimals());
    }

    /// @dev Mint ~0.5 share worth (= ~half the deposit). Computed in share units so it never collapses
    /// to dust on 18-decimal share tokens.
    function _mintShares() internal view returns (uint256) {
        return vault.convertToShares(_depositAmount() / 2);
    }

    /// @dev Allocate whatever idle the vault holds at the moment of the call (post-deposit/mint).
    function _allocateAmount() internal view returns (uint256) {
        return asset.balanceOf(address(vault));
    }

    /// @dev Pull back half of the strategy's current position so the report can show both the
    /// strategy-still-has-yield and vault-now-has-idle states in the same run.
    function _deallocateAmount() internal view returns (uint256) {
        return strategy.totalAssets() / 2;
    }

    /// @dev Withdraw all current vault idle (post-deallocate).
    function _withdrawAmount() internal view returns (uint256) {
        return asset.balanceOf(address(vault));
    }

    /// @dev Time-skip 180 days — long enough to show non-trivial yield even at testnet rates.
    function _skipSeconds() internal pure returns (uint256) {
        return 180 days;
    }

    /* ─────────────────────────── TEST CASES ─────────────────────────── */

    function _case_deposit() internal {
        uint256 amt = _depositAmount();
        require(asset.balanceOf(user) >= amt, "user underfunded");
        Snap memory b = _snap();
        uint256 shares = vault.deposit(amt, user);
        _emit(
            "deposit_to_vault",
            unicode"User가 underlying을 Vault에 예치하고 share를 발행받는다. 아직 Aqua 풀에는 들어가지 않음.",
            string.concat("vault.deposit(", vm.toString(amt), ", user) -> ", vm.toString(shares), " shares"),
            b,
            _snap()
        );
    }

    function _case_mint() internal {
        uint256 shares = _mintShares();
        Snap memory b = _snap();
        uint256 paid = vault.mint(shares, user);
        _emit(
            "mint_to_vault",
            unicode"정확한 share 양을 발행받고 미리 계산된 underlying을 지불 (deposit의 dual).",
            string.concat("vault.mint(", vm.toString(shares), ", user) costs ", vm.toString(paid)),
            b,
            _snap()
        );
    }

    function _case_allocate() internal {
        uint256 amt = _allocateAmount();
        Snap memory b = _snap();
        vault.allocate(address(strategy), hex"", amt);
        _emit(
            "allocate_to_aqua",
            unicode"Vault의 idle underlying을 AquaStrategy로 보내고, strategy는 Aqua(Aave V2) 풀에 공급한다. "
            unicode"Strategy의 aToken 잔고가 늘고 풀 유동성도 같은 만큼 증가.",
            string.concat("vault.allocate(strategy, ", vm.toString(amt), ") -> pool.deposit"),
            b,
            _snap()
        );
    }

    function _case_skipTime() internal {
        Snap memory b = _snap();
        uint256 dt = _skipSeconds();
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + dt / 12);
        _emit(
            "time_skip",
            unicode"포크 전용: vm.warp로 시간을 건너뛴다. Aqua 풀에 차입이 있다면 normalizedIncome이 상승하고 "
            unicode"이에 비례해 strategy의 aToken 잔고가 자동으로 증가 (rebasing). 이 aToken 이자는 vault.totalAssets로 "
            unicode"흘러들어 **sharePrice 상승**으로 이어진다 (broadcast 모드에서 표에 반영; fork 모드는 sharePrice 컬럼 고정 — "
            unicode"헤더 주석 참조). 단위테스트 `testATokenInterestRaisesVaultSharePrice`가 sharePrice 상승을 단언한다.",
            string.concat("vm.warp(+", vm.toString(dt), "s)"),
            b,
            _snap()
        );
    }

    function _case_deallocate() internal {
        uint256 amt = _deallocateAmount();
        Snap memory b = _snap();
        vault.deallocate(address(strategy), hex"", amt);
        _emit(
            "deallocate_from_aqua",
            unicode"Strategy가 Aqua 풀에서 underlying을 인출(burn aToken) → Vault로 돌려준다. "
            unicode"풀 유동성이 감소하고, Vault의 idle balance가 증가.",
            string.concat("vault.deallocate(strategy, ", vm.toString(amt), ") -> pool.withdraw"),
            b,
            _snap()
        );
    }

    /// @dev Case 1: vault has enough idle → withdraw settles IMMEDIATELY. Takes 1/3 of current idle
    /// to leave headroom for the follow-up "queued" case.
    function _case_withdrawImmediate() internal {
        uint256 idle = asset.balanceOf(address(vault));
        if (idle == 0) return;
        uint256 amt = idle / 3;
        if (amt == 0) amt = 1;
        Snap memory b = _snap();
        uint256 burned = vault.withdraw(amt, user, user);
        _emit(
            "withdraw_immediate",
            unicode"**Case 1**: vault에 idle이 충분 → 즉시 정산. user는 share burn하고 underlying을 바로 수령. "
            unicode"`pendingWithdrawal` 큐에는 들어가지 않음.",
            string.concat(
                "vault.withdraw(", vm.toString(amt), ", user, user) burns ", vm.toString(burned), unicode" shares (즉시 정산)"
            ),
            b,
            _snap()
        );
    }

    /// @dev Case 2: withdraw amount > vault idle → goes to queue. Share is burned but underlying is
    /// not delivered yet; the request waits in `pendingWithdrawal[user]` for fulfillment.
    function _case_withdrawQueued() internal {
        uint256 idle = asset.balanceOf(address(vault));
        // Demand 1.5× current idle so the full request must queue (Vault queues the WHOLE request
        // when idle is insufficient — it doesn't partially settle).
        uint256 amt = idle == 0 ? _depositAmount() : idle + idle / 2;
        uint256 userMax = vault.convertToAssets(vault.balanceOf(user));
        if (amt > userMax) amt = userMax;
        if (amt == 0) return;
        Snap memory b = _snap();
        uint256 burned = vault.withdraw(amt, user, user);
        _emit(
            "withdraw_queued",
            unicode"**Case 2**: withdraw 금액이 vault idle을 초과 → `pendingWithdrawal[user]`로 큐 진입. "
            unicode"share는 burn됐지만 underlying은 아직 미수령. 이후 fulfillWithdrawal + claim 필요.",
            string.concat(
                "vault.withdraw(", vm.toString(amt), ", user, user) burns ", vm.toString(burned),
                unicode" shares (큐 대기, idle ", vm.toString(idle), unicode" 부족)"
            ),
            b,
            _snap()
        );
    }

    /// @dev Redeem is the dual of withdraw — input is shares, output is underlying. Uses the SAME
    /// internal `_exit`, so the queue behavior is identical to withdraw. Here we use 1/8 of user's
    /// remaining shares; whether it settles immediately or queues depends on vault idle at runtime.
    function _case_redeem() internal {
        uint256 shares = vault.balanceOf(user) / 8;
        if (shares == 0) return;
        Snap memory b = _snap();
        uint256 got = vault.redeem(shares, user, user);
        _emit(
            "redeem_with_yield",
            unicode"Withdraw의 dual: input이 underlying이 아닌 share. 내부적으로 같은 `_exit` 경로라 큐 동작도 동일. "
            unicode"vault.idle이 부족하면 함께 큐에 누적됨 (이전 withdraw_queued 요청과 합산).",
            string.concat("vault.redeem(", vm.toString(shares), ", user, user) -> ", vm.toString(got), " underlying"),
            b,
            _snap()
        );
    }

    /// @dev Settles a queued withdrawal. Withdraw/redeem with insufficient idle drops the request
    /// into `pendingWithdrawal[user]`. We (a) ensure vault has enough idle by deallocating from
    /// AquaStrategy if needed, (b) run `fulfillWithdrawal` to move pending → claimable, then
    /// (c) `claim(user)` pays it out.
    /// Steps (a) and (b) need ALLOCATOR (operator); (c) is callable by anyone.
    function _case_claim() internal {
        (uint128 pendingAssets,,) = vault.pendingWithdrawal(user);
        if (pendingAssets == 0) return; // nothing queued

        // (a) Ensure vault has enough idle. Pull from AquaStrategy if needed (operator is ALLOCATOR).
        _asOperator();
        uint256 idle = asset.balanceOf(address(vault));
        uint256 deallocateAmount;
        if (idle < pendingAssets) {
            uint256 missing = pendingAssets - idle;
            uint256 strategyHas = strategy.totalAssets();
            uint256 toPull = missing > strategyHas ? strategyHas : missing;
            if (toPull > 0) {
                vault.deallocate(address(strategy), hex"", toPull);
                deallocateAmount = toPull;
            }
        }

        // (b) Fulfill the pending withdrawal — moves it to claimable. ALLOCATOR-gated.
        // Capture per-user pending amount BEFORE the call (after fulfill it's zero).
        address[] memory list = new address[](1);
        list[0] = user;
        uint128 fulfilledForUser = pendingAssets;
        vault.fulfillWithdrawal(list);

        // (c) Claim — anyone can call; the funds go to `user`.
        Snap memory b = _snap();
        uint256 netReceived = vault.claim(user);

        // Build a detailed per-step description with embedded tx hash markers (replaced by
        // BuildReport in live mode; left as HTML comments in fork mode = invisible).
        string memory detail = unicode"\n\n**처리 상세:**\n\n";
        if (deallocateAmount > 0) {
            detail = string.concat(
                detail,
                unicode"- **deallocate** (operator → AquaStrategy): ",
                vm.toString(deallocateAmount), unicode" wei 회수\n",
                unicode"  ↳ tx: <!-- TX:claim_queued_withdrawal_deallocate -->\n"
            );
        } else {
            detail = string.concat(detail, unicode"- **deallocate**: 생략 (vault idle 충분)\n");
        }
        detail = string.concat(
            detail,
            unicode"- **fulfillWithdrawal** (operator, ALLOCATOR_ROLE): 대상 `[",
            vm.toString(user), unicode" (user)]` → ", vm.toString(fulfilledForUser),
            unicode" wei를 `pending` → `claimable`로 이동\n",
            unicode"  ↳ tx: <!-- TX:claim_queued_withdrawal_fulfill -->\n",
            unicode"- **claim** (anyone, 수령자=user): ", vm.toString(user),
            unicode" → ", vm.toString(netReceived), unicode" wei net 전달 (fee 차감 후)\n",
            unicode"  ↳ tx: <!-- TX:claim_queued_withdrawal -->\n"
        );

        _emit(
            "claim_queued_withdrawal",
            string.concat(
                unicode"이전 `withdraw_queued` / `redeem` 요청이 idle 부족으로 `pendingWithdrawal` 큐에 진입한 상태. "
                unicode"여기서 3단계로 정산한다.",
                detail
            ),
            string.concat(
                deallocateAmount > 0
                    ? "vault.deallocate(...); vault.fulfillWithdrawal([user]); vault.claim(user) -> "
                    : "vault.fulfillWithdrawal([user]); vault.claim(user) -> ",
                vm.toString(netReceived)
            ),
            b,
            _snap()
        );
    }

    /// @dev Demonstrates per-user accounting isolation in the withdrawal queue: two depositors
    /// (deployer + operator) both queue, the operator fulfills BOTH in one batch, and each can claim
    /// ONLY their own reserved amount. Mirrors the unit test `testMultiplePendingUsersClaimOnlyOwnAllocation`.
    /// Self-contained — does not touch the main `user`'s position. Skips if depositors are underfunded.
    function _case_multiUserClaimIsolation() internal {
        address a = deployer;
        address bb = operator;
        uint256 each = _depositAmount() / 4;
        if (each == 0) each = 1;

        if (!live) {
            if (asset.balanceOf(a) < each) deal(address(asset), a, each);
            if (asset.balanceOf(bb) < each) deal(address(asset), bb, each);
        } else if (asset.balanceOf(a) < each || asset.balanceOf(bb) < each) {
            console.log("[skip] multi_user_claim_isolation: depositors underfunded");
            return;
        }

        Snap memory before = _snap();

        // Both deposit.
        _asDeployer();
        asset.approve(address(vault), each);
        uint256 sharesA = vault.deposit(each, a);
        _asOperator();
        asset.approve(address(vault), each);
        uint256 sharesB = vault.deposit(each, bb);

        // Drain all FREE idle (balance minus already-reserved claims) into the strategy so both
        // redeems are forced to queue rather than settle immediately.
        uint256 bal = asset.balanceOf(address(vault));
        uint256 reserved = vault.pendingClaimableAssets();
        uint256 free = bal > reserved ? bal - reserved : 0;
        if (free > 0) vault.allocate(address(strategy), hex"", free);

        // Both redeem everything -> fully queued.
        _asDeployer();
        vault.redeem(sharesA, a, a);
        _asOperator();
        vault.redeem(sharesB, bb, bb);

        (uint128 pendA,,) = vault.pendingWithdrawal(a);
        (uint128 pendB,,) = vault.pendingWithdrawal(bb);

        // Operator restores liquidity and fulfills BOTH at once.
        uint256 need = uint256(pendA) + uint256(pendB);
        uint256 vaultIdle = asset.balanceOf(address(vault));
        if (vaultIdle < need) {
            uint256 missing = need - vaultIdle;
            uint256 has = strategy.totalAssets();
            vault.deallocate(address(strategy), hex"", missing > has ? has : missing);
        }
        address[] memory list = new address[](2);
        list[0] = a;
        list[1] = bb;
        vault.fulfillWithdrawal(list);

        uint256 claimA = vault.claimableAssets(a);
        uint256 claimB = vault.claimableAssets(bb);

        // Each claims; we measure the per-account receipt to prove isolation.
        uint256 balA0 = asset.balanceOf(a);
        uint256 gotA = vault.claim(a);
        uint256 balB0 = asset.balanceOf(bb);
        uint256 gotB = vault.claim(bb);

        string memory detail = string.concat(
            unicode"\n\n**처리 상세:** 메인 `트랜잭션`은 operator의 `fulfillWithdrawal([A,B])` 배치 정산이고, "
            unicode"claim은 계정별로 각각 1건씩 (총 2건) 발생한다.\n\n",
            unicode"**격리 증명 (각자 자기 몫만 수령):**\n\n",
            unicode"- A(deployer) `", vm.toString(a), unicode"`: 예약 ", vm.toString(claimA),
            unicode" → claim 수령 ", vm.toString(gotA), unicode" (실제 잔고 +", vm.toString(asset.balanceOf(a) - balA0), unicode")\n",
            unicode"  ↳ tx: <!-- TX:multi_user_claim_a -->\n",
            unicode"- B(operator) `", vm.toString(bb), unicode"`: 예약 ", vm.toString(claimB),
            unicode" → claim 수령 ", vm.toString(gotB), unicode" (실제 잔고 +", vm.toString(asset.balanceOf(bb) - balB0), unicode")\n",
            unicode"  ↳ tx: <!-- TX:multi_user_claim_b -->\n",
            unicode"- A의 claim은 B의 예약분을 건드릴 수 없고 그 반대도 성립 — `reservedAssets`에서 각자 자기 몫만 차감된다."
        );

        Snap memory afterSnap = _snap();

        _emit(
            "multi_user_claim_isolation",
            string.concat(
                unicode"여러 유저가 동시에 출금 큐에 들어가도 각자 **자기에게 fulfill된 예약분만** claim할 수 있음을 보인다. "
                unicode"deployer·operator 두 계정이 각각 예치 후 전량 redeem → idle 부족으로 둘 다 `pendingWithdrawal` 큐 진입 → "
                unicode"operator가 한 번의 `fulfillWithdrawal([A,B])`로 둘 다 정산 가능 상태로 만든 뒤, 각자 claim하면 정확히 본인 몫만 수령. "
                unicode"main `user`의 포지션과는 무관한 독립 시나리오.",
                detail
            ),
            string.concat(
                "deposit x2; allocate; redeem x2 (queue); fulfillWithdrawal([A,B]); claim(A)=",
                vm.toString(gotA), ", claim(B)=", vm.toString(gotB)
            ),
            before,
            afterSnap
        );
    }

    /* ─────────────────── OFFCHAIN NAV STRATEGY ─────────────────── */

    /// @dev Move vault idle into OffchainNAVStrategy as onchain idle (not yet sent to custodian).
    function _case_offchainAllocate() internal {
        if (address(offchain) == address(0)) return;
        uint256 amt = asset.balanceOf(address(vault));
        if (amt == 0) {
            console.log("[skip] vault idle == 0; reorder scenarios or increase deposit");
            return;
        }
        Snap memory b = _snap();
        vault.allocate(address(offchain), hex"", amt);
        _emitOffchain(
            "allocate_to_offchain",
            unicode"Vault의 idle을 OffchainNAVStrategy로 보낸다. 자산은 strategy의 onchain idle로만 들어가고 "
            unicode"아직 custodian으로 송금되지 않은 상태.",
            string.concat("vault.allocate(offchain, ", vm.toString(amt), ")"),
            b,
            _snap()
        );
    }

    /// @dev Manager moves the strategy's onchain idle to the offchain custodian (simulating an
    /// RWA capital deployment), then the reporter immediately confirms the deployed NAV. Without
    /// the confirmation `lastReportTime == 0` keeps `isStale() == true` and `totalAssets()` would
    /// drop to onchain idle only (= 0), which is the protocol's safety fallback against unverified
    /// offchain claims.
    function _case_deployToCustodian() internal {
        if (address(offchain) == address(0)) return;
        uint256 amt = asset.balanceOf(address(offchain));
        if (amt == 0) return;
        Snap memory b = _snap();
        offchain.deployToCustodian(amt);
        // Confirmation NAV report — flips isStale false so totalAssets includes the offchain part.
        offchain.report(amt, amt, 0, keccak256(abi.encode("deploy-confirm", caseNo)), "ipfs://deploy-confirm");
        _emitOffchain(
            "deploy_to_custodian",
            unicode"OFFCHAIN_MANAGER가 strategy의 onchain idle을 custodian으로 송금하고 "
            unicode"OFFCHAIN_REPORTER가 즉시 deployment를 NAV로 확정 보고한다. "
            unicode"totalAssets은 보존(onchain idle 감소 = reportedAssets 증가).",
            string.concat(
                "offchain.deployToCustodian(", vm.toString(amt),
                ") + offchain.report(", vm.toString(amt), ", ...)"
            ),
            b,
            _snap()
        );
    }

    /// @dev Reporter posts a NAV update simulating a 1% gain on the offchain position.
    function _case_navReport() internal {
        if (address(offchain) == address(0)) return;
        uint256 currentReported = offchain.reportedAssets();
        if (currentReported == 0) return;
        // 1% gain
        uint256 newReported = currentReported + (currentReported / 100);
        Snap memory b = _snap();
        offchain.report(newReported, 0, 0, keccak256(abi.encode("scenario", caseNo)), "ipfs://scenario-report");
        _emitOffchain(
            "nav_report_gain",
            unicode"OFFCHAIN_REPORTER가 NAV 1% 상승을 보고. reportedAssets 증가 → strategy.totalAssets 증가 "
            unicode"→ vault.totalAssets 증가 → **sharePrice 상승** (broadcast 모드의 다음 accrueInterest에서 표에 반영; "
            unicode"fork 모드는 firstTotalAssets transient 한계로 sharePrice 컬럼이 안 움직임 — 헤더 주석 참조). "
            unicode"단위테스트 `testOffchainNAVGainRaisesSharePrice`가 sharePrice 상승을 단언한다.",
            string.concat(
                "offchain.report(", vm.toString(newReported), ", 0, 0, hash, uri)"
            ),
            b,
            _snap()
        );
    }

    /// @dev Custodian (account 2) physically sends half of its holdings back to the strategy.
    /// Then the deployer (= reporter) posts an updated NAV reflecting the return.
    /// Works in both fork and live mode because we switch the broadcaster per action.
    function _case_returnFromCustodian() internal {
        if (address(offchain) == address(0)) return;
        uint256 reported = offchain.reportedAssets();
        uint256 amt = reported / 2;
        if (amt == 0) return;
        if (asset.balanceOf(custodian) < amt) {
            console.log("[skip] custodian USDT < return amount; pre-fund custodian or skip");
            return;
        }

        Snap memory b = _snap();

        // 1) Custodian broadcasts the USDT return.
        _asCustodian();
        asset.transfer(address(offchain), amt);

        // 2) Operator (= reporter) posts the new NAV.
        _asOperator();
        uint256 newReported = reported - amt;
        offchain.report(newReported, 0, 0, keccak256(abi.encode("return", caseNo)), "ipfs://return");

        _emitOffchain(
            "return_from_custodian",
            unicode"Custodian이 자산 절반을 strategy로 반환 + reporter가 새 NAV 보고. "
            unicode"reportedAssets 감소, strategy onchain idle 증가, totalAssets은 보존(yield 무시).",
            string.concat("custodian.transfer(strategy, ", vm.toString(amt), ") + report(newAssets)"),
            b,
            _snap()
        );
    }

    /// @dev Pull onchain idle back from offchain strategy to vault. Mirrors deallocate_from_aqua.
    function _case_offchainDeallocate() internal {
        if (address(offchain) == address(0)) return;
        uint256 amt = asset.balanceOf(address(offchain));
        if (amt == 0) return;
        Snap memory b = _snap();
        vault.deallocate(address(offchain), hex"", amt);
        _emitOffchain(
            "deallocate_from_offchain",
            unicode"Strategy의 onchain idle을 Vault로 회수. Offchain 회계상 변화는 onchain idle 감소만 보임 "
            unicode"(reportedAssets는 그대로 — custodian이 들고 있는 부분).",
            string.concat("vault.deallocate(offchain, ", vm.toString(amt), ")"),
            b,
            _snap()
        );
    }

    function _case_pause() internal {
        Snap memory b = _snap();
        vault.pause();
        vault.unpause();
        _emit(
            "pause_unpause",
            unicode"SENTINEL이 pause하여 deposit/mint를 차단하고, GOVERNANCE가 unpause. 잔고에는 영향 없음.",
            "vault.pause(); vault.unpause();",
            b,
            _snap()
        );
    }

    /* ─────────────────────────── HELPERS ─────────────────────────── */

    function _enabled(string memory name) internal view returns (bool) {
        string memory list = vm.envOr("SCENARIOS", string(""));
        if (bytes(list).length == 0) return true;
        bytes memory L = bytes(list);
        bytes memory N = bytes(name);
        uint256 i;
        while (i < L.length) {
            uint256 j;
            while (j < N.length && i + j < L.length && L[i + j] == N[j]) {
                j++;
            }
            bool atEnd = i + j == L.length;
            bool atComma = i + j < L.length && L[i + j] == ",";
            if (j == N.length && (atEnd || atComma)) return true;
            while (i < L.length && L[i] != ",") i++;
            if (i < L.length) i++;
        }
        return false;
    }

    function _snap() internal view returns (Snap memory s) {
        s.totalAssets = vault.totalAssets();
        s.totalSupply = vault.totalSupply();
        s.sharePrice = s.totalSupply == 0 ? 0 : vault.convertToAssets(1e18);
        s.userShares = vault.balanceOf(user);
        s.userAsset = asset.balanceOf(user);
        s.vaultAsset = asset.balanceOf(address(vault));
        (uint128 pa,,) = vault.pendingWithdrawal(user);
        s.userPendingAssets = uint256(pa);
        s.userClaimableAssets = uint256(vault.claimableAssets(user));
        s.strategyAssets = strategy.totalAssets();
        s.strategyATokenBal = aToken.balanceOf(address(strategy));
        s.strategyWrittenOff = strategy.writtenOff();
        s.poolLiquidity = asset.balanceOf(address(aToken));
        s.poolATokenSupply = aToken.totalSupply();
        s.poolImpliedDebt =
            s.poolATokenSupply > s.poolLiquidity ? s.poolATokenSupply - s.poolLiquidity : 0;
        try pool.getReserveNormalizedIncome(address(asset)) returns (uint256 v) {
            s.normalizedIncome = v;
        } catch {}
        try pool.getReserveNormalizedVariableDebt(address(asset)) returns (uint256 v) {
            s.normalizedDebt = v;
        } catch {}

        if (address(offchain) != address(0)) {
            s.offTotalAssets = offchain.totalAssets();
            s.offIdle = asset.balanceOf(address(offchain));
            s.offReportedAssets = offchain.reportedAssets();
            s.offReportedAvailableLiquidity = offchain.reportedAvailableLiquidity();
            s.offPendingReceivable = offchain.pendingReceivable();
            s.offStrictMode = offchain.strictMode();
            s.offIsStale = offchain.isStale();
        }
        s.custodianBal = custodian != address(0) ? asset.balanceOf(custodian) : 0;
    }

    function _emit(string memory name, string memory desc, string memory call, Snap memory b, Snap memory a)
        internal
    {
        caseNo++;
        string memory t = string.concat(
            unicode"### 시나리오 ",
            vm.toString(caseNo),
            unicode" - `",
            name,
            "`\n\n",
            desc,
            "\n\n",
            unicode"**호출:** `",
            call,
            "`\n\n",
            unicode"**트랜잭션:** <!-- TX:",
            name,
            " -->\n\n"
        );

        t = string.concat(t, unicode"#### Vault 상태\n\n");
        t = string.concat(t, unicode"| 항목 | 이전 | 이후 | 변화 |\n|---|---:|---:|---:|\n");
        t = string.concat(t, _row("totalAssets", b.totalAssets, a.totalAssets));
        t = string.concat(t, _row(unicode"totalSupply (총 share)", b.totalSupply, a.totalSupply));
        t = string.concat(t, _row("sharePrice (asset / 1e18)", b.sharePrice, a.sharePrice));
        t = string.concat(t, _row(unicode"user share 보유량", b.userShares, a.userShares));
        t = string.concat(t, _row(unicode"user underlying 보유량", b.userAsset, a.userAsset));
        t = string.concat(t, _row(unicode"vault underlying idle", b.vaultAsset, a.vaultAsset));
        t = string.concat(t, _row(unicode"user pending (큐 대기)", b.userPendingAssets, a.userPendingAssets));
        t = string.concat(t, _row(unicode"user claimable (정산 대기)", b.userClaimableAssets, a.userClaimableAssets));

        t = string.concat(t, unicode"\n#### AquaStrategy 상태\n\n");
        t = string.concat(t, unicode"| 항목 | 이전 | 이후 | 변화 |\n|---|---:|---:|---:|\n");
        t = string.concat(t, _row(unicode"strategy.totalAssets()", b.strategyAssets, a.strategyAssets));
        t = string.concat(t, _row(unicode"strategy aToken 잔고", b.strategyATokenBal, a.strategyATokenBal));
        t = string.concat(t, _row(unicode"strategy writtenOff", b.strategyWrittenOff, a.strategyWrittenOff));

        t = string.concat(t, unicode"\n#### Aqua 풀 상태\n\n");
        t = string.concat(t, unicode"| 항목 | 이전 | 이후 | 변화 |\n|---|---:|---:|---:|\n");
        t = string.concat(t, _row(unicode"풀 유동성 (asset @ aToken)", b.poolLiquidity, a.poolLiquidity));
        t = string.concat(t, _row(unicode"풀 aToken 총공급", b.poolATokenSupply, a.poolATokenSupply));
        t = string.concat(t, _row(unicode"풀 추정 총부채", b.poolImpliedDebt, a.poolImpliedDebt));
        t = string.concat(t, _row("normalizedIncome (ray)", b.normalizedIncome, a.normalizedIncome));
        t = string.concat(t, _row("normalizedDebt (ray)", b.normalizedDebt, a.normalizedDebt));

        body = string.concat(body, t, "\n");
    }

    /// @dev Offchain-flavored emit: Vault + OffchainStrategy + Custodian tables (no Aqua section).
    function _emitOffchain(string memory name, string memory desc, string memory call, Snap memory b, Snap memory a)
        internal
    {
        caseNo++;
        string memory t = string.concat(
            unicode"### 시나리오 ",
            vm.toString(caseNo),
            unicode" - `",
            name,
            "`\n\n",
            desc,
            "\n\n",
            unicode"**호출:** `",
            call,
            "`\n\n",
            unicode"**트랜잭션:** <!-- TX:",
            name,
            " -->\n\n"
        );

        t = string.concat(t, unicode"#### Vault 상태\n\n");
        t = string.concat(t, unicode"| 항목 | 이전 | 이후 | 변화 |\n|---|---:|---:|---:|\n");
        t = string.concat(t, _row("totalAssets", b.totalAssets, a.totalAssets));
        t = string.concat(t, _row(unicode"totalSupply (총 share)", b.totalSupply, a.totalSupply));
        t = string.concat(t, _row("sharePrice (asset / 1e18)", b.sharePrice, a.sharePrice));
        t = string.concat(t, _row(unicode"user share 보유량", b.userShares, a.userShares));
        t = string.concat(t, _row(unicode"user underlying 보유량", b.userAsset, a.userAsset));
        t = string.concat(t, _row(unicode"vault underlying idle", b.vaultAsset, a.vaultAsset));
        t = string.concat(t, _row(unicode"user pending (큐 대기)", b.userPendingAssets, a.userPendingAssets));
        t = string.concat(t, _row(unicode"user claimable (정산 대기)", b.userClaimableAssets, a.userClaimableAssets));

        t = string.concat(t, unicode"\n#### OffchainNAVStrategy 상태\n\n");
        t = string.concat(t, unicode"| 항목 | 이전 | 이후 | 변화 |\n|---|---:|---:|---:|\n");
        t = string.concat(t, _row(unicode"totalAssets", b.offTotalAssets, a.offTotalAssets));
        t = string.concat(t, _row(unicode"strategy onchain idle", b.offIdle, a.offIdle));
        t = string.concat(t, _row(unicode"reportedAssets (offchain NAV)", b.offReportedAssets, a.offReportedAssets));
        t = string.concat(t, _row(unicode"reportedAvailableLiquidity", b.offReportedAvailableLiquidity, a.offReportedAvailableLiquidity));
        t = string.concat(t, _row(unicode"pendingReceivable", b.offPendingReceivable, a.offPendingReceivable));
        t = string.concat(t, unicode"| strictMode | ", b.offStrictMode ? "true" : "false", " | ", a.offStrictMode ? "true" : "false", " | - |\n");
        t = string.concat(t, unicode"| isStale | ", b.offIsStale ? "true" : "false", " | ", a.offIsStale ? "true" : "false", " | - |\n");

        t = string.concat(t, unicode"\n#### Custodian 상태\n\n");
        t = string.concat(t, unicode"| 항목 | 이전 | 이후 | 변화 |\n|---|---:|---:|---:|\n");
        t = string.concat(t, _row(unicode"custodian underlying 잔고", b.custodianBal, a.custodianBal));

        body = string.concat(body, t, "\n");
    }

    function _row(string memory name, uint256 b, uint256 a) internal pure returns (string memory) {
        int256 d = int256(a) - int256(b);
        return string.concat("| ", name, " | ", vm.toString(b), " | ", vm.toString(a), " | ", vm.toString(d), " |\n");
    }

    function _header() internal view returns (string memory) {
        string memory h = unicode"# Aqua Vault - 통합 시나리오 리포트\n\n";
        h = string.concat(h, unicode"- 모드               : ", live ? unicode"**라이브 (broadcast)**" : unicode"**포크 시뮬레이션**", "\n");
        h = string.concat(h, unicode"- 체인 ID            : ", vm.toString(block.chainid), "\n");
        h = string.concat(h, unicode"- 블록               : ", vm.toString(block.number), "\n");
        h = string.concat(h, unicode"- Deployer (admin)   : ", vm.toString(deployer), "\n");
        h = string.concat(h, unicode"- User (depositor)   : ", vm.toString(user), "\n");
        h = string.concat(h, unicode"- Custodian (offchain): ", vm.toString(custodian), "\n");
        h = string.concat(h, unicode"- Operator (ops)     : ", vm.toString(operator), "\n");
        h = string.concat(h, "- Vault              : ", vm.toString(address(vault)), "\n");
        h = string.concat(h, "- StrategyManager    : ", vm.toString(address(sm)), "\n");
        h = string.concat(h, "- AquaStrategy       : ", vm.toString(address(strategy)), "\n");
        h = string.concat(h, "- Aqua Pool          : ", vm.toString(address(pool)), "\n");
        h = string.concat(h, "- aToken             : ", vm.toString(address(aToken)), "\n");
        h = string.concat(h, "- OffchainStrategy   : ", vm.toString(address(offchain)), "\n");
        h = string.concat(h, unicode"- Underlying 자산    : ", vm.toString(address(asset)), "\n\n");
        h = string.concat(
            h,
            unicode"> 모든 ray(1e27) 단위 값은 1e27을 1.0으로 본다. normalizedIncome 증가 = supply 이자 누적, "
            unicode"normalizedDebt 증가 = borrow 이자 누적.\n\n"
        );
        if (!live) {
            h = string.concat(
                h,
                unicode"> **Fork 모드 한계 (yield ↔ sharePrice 표시)**: Vault의 `firstTotalAssets`가 "
                unicode"transient storage라서, 운영 환경에선 매 tx마다 0으로 리셋되어 yield가 매 호출마다 "
                unicode"sharePrice에 반영됩니다. 하지만 forge script의 fork 모드는 **모든 시나리오를 "
                unicode"한 EVM 컨텍스트로 묶어 실행**하므로 첫 vault 호출 이후 `accrueInterest`가 모두 no-op이 "
                unicode"되어 Vault의 `totalAssets`/`sharePrice`에 yield가 안 보입니다. Strategy 쪽 yield "
                unicode"(aToken 잔고 증가)는 정상적으로 보이며, **`--broadcast` 모드로 돌리면** (각 호출이 진짜 "
                unicode"tx) 두 값이 정확히 일치합니다.\n\n"
            );
        }
        return h;
    }

    function _write() internal {
        if (live) {
            vm.writeFile("reports/_scenario_header.md", _header());
            vm.writeFile("reports/_scenario_body.md", body);
            console.log("Wrote reports/_scenario_header.md + reports/_scenario_body.md");
            console.log("Next: forge script script/BuildReport.s.sol --sig 'buildScenario()'");
        } else {
            string memory note = unicode"## 트랜잭션\n\n"
                unicode"_포크 시뮬레이션: 온체인 트랜잭션 해시 없음. 라이브 리포트는 `--broadcast`로 다시 실행하세요._\n\n";
            vm.writeFile("reports/scenario-fork.md", string.concat(_header(), note, body));
            console.log("Wrote reports/scenario-fork.md");
        }
    }
}
