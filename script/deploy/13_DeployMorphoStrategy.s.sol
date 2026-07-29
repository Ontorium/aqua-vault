// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {MorphoStrategy} from "../../src/strategies/MorphoStrategy.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {StrategyManager} from "../../src/StrategyManager.sol";
import {Vault} from "../../src/Vault.sol";
import {WAD} from "../../src/libraries/ConstantsLib.sol";
import {MarketParams, Id} from "../../src/strategies/morpho/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../src/strategies/morpho/libraries/MarketParamsLib.sol";
import {EnvSigner} from "../EnvSigner.sol";
import {DeployConfig} from "../DeployConfig.sol";
import {MorphoMock} from "../../test/mocks/MorphoMock.sol";
import {IrmMock} from "../../test/mocks/IrmMock.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";

/// @notice Step 13 — deploy a MorphoStrategy for an existing vault and wire it into the vault's
/// StrategyManager. Mirrors step 9 (AquaStrategy) but for an onchain Morpho-supply strategy.
/// Registers kind=1 (ONCHAIN) so it lands in the "DeFi" allocation bucket alongside Aqua.
///
/// The signer self-grants the vault-scoped GOVERNANCE_ROLE (admined by DEFAULT_ADMIN_ROLE),
/// adds the strategy, and always lifts the strategy-level cap.
///
/// Repeat once per vault: each vault needs its OWN MorphoStrategy instance (vault/asset are
/// immutable at construction).
///
/// If `morpho` is unresolved (arg=0 and config has no Morpho), the script falls back to TESTNET
/// demo mode and deploys:
///   - MorphoMock
///   - IrmMock
///   - mock collateral
/// then whitelists the IRM and lifts collateral/market caps for this canonical demo market:
///   MarketParams{ loanToken: vault.asset(), collateralToken: <mock>, oracle: 0, irm: <mock>, lltv: 0.86e18 }
/// The abi-encoded params are logged so an ALLOCATOR can later run:
///   vault.allocate(strategy, <encodedMarketParams>, assets)
///
/// If `morpho` is provided (explicit arg or config.external.morpho), the default 4-arg entrypoint
/// assumes a REAL market already exists and does NOT deploy mocks or set market/collateral caps. In
/// that mode you must separately:
///   1. approve the real IRM via `strategy.setIrmApproved(realIrm, true)`
///   2. lift caps for the real collateral id
///   3. lift caps for the real market id
///
/// For TESTING with an existing mock Morpho, use either:
///   - the 5-arg entrypoint with `setupMockMarket = true`, which deploys a fresh IrmMock and
///     mock collateral automatically, or
///   - the 6-arg entrypoint and pass explicit `collateral` and `irm`.
///
/// Both paths wire the canonical demo market params onto the newly deployed strategy and do the
/// pre-allocation setup only:
///   1. approve IRM on the strategy
///   2. lift the collateral id cap
///   3. lift the market id cap
/// Allocate remains a separate explicit step.
///
/// Args:
///   vault           Vault contract (its `asset()` is read to wire the strategy)
///   strategyManager Vault's StrategyManager (per-vault instance)
///   roleManager     Shared RoleManager
///   morpho          Morpho Blue protocol (0 -> config.external.morpho; still 0 -> deploy a MOCK +
///                   mock IRM/collateral + a demo market, for testnet only)
///
/// Required env: PRIVATE_KEY or MNEMONIC (signer must hold DEFAULT_ADMIN_ROLE on RoleManager).
///
/// Usage (mock, testnet):
///   forge script script/deploy/13_DeployMorphoStrategy.s.sol \
///     --sig "run(address,address,address,address)" \
///     0xVault 0xStrategyManager 0xRoleManager 0x0 \
///     --rpc-url arbitrum_sepolia --broadcast
contract DeployMorphoStrategy is EnvSigner, DeployConfig {
    using MarketParamsLib for MarketParams;

    function run(address vaultAddr, address smAddr, address rmAddr, address morpho) external {
        _run(vaultAddr, smAddr, rmAddr, morpho, address(0), address(0), false);
    }

    function run(address vaultAddr, address smAddr, address rmAddr, address morpho, bool setupMockMarket) external {
        _run(vaultAddr, smAddr, rmAddr, morpho, address(0), address(0), setupMockMarket);
    }

    function run(
        address vaultAddr,
        address smAddr,
        address rmAddr,
        address morpho,
        address collateral,
        address irm
    ) external {
        _run(vaultAddr, smAddr, rmAddr, morpho, collateral, irm, false);
    }

    function _run(
        address vaultAddr,
        address smAddr,
        address rmAddr,
        address morpho,
        address collateral,
        address irm,
        bool deployMockMarketComponents
    ) internal {
        Vault vault = Vault(vaultAddr);
        address asset = vault.asset();
        RoleManager rm = RoleManager(rmAddr);
        StrategyManager sm = StrategyManager(smAddr);

        // Per-network config: morpho address + strategy knobs (caps / targetBps / penalty / skim) and,
        // for a real market, the market params (collateral/oracle/irm/lltv).
        bool hasCfg = _configAvailable();
        Config memory c;
        if (hasCfg) c = _loadConfig();
        // Resolve Morpho: explicit arg -> config.external.morpho -> (still 0) deploy a fresh MorphoMock.
        if (morpho == address(0)) morpho = c.morpho;

        address signer = _startBroadcastFromEnv();

        // 1. If no Morpho was resolved, deploy a fresh mock protocol.
        bool deployedMockMorpho = morpho == address(0);
        if (deployedMockMorpho) morpho = address(new MorphoMock());

        // 2. Deploy the strategy bound to (vault, asset, morpho).
        MorphoStrategy strategy = new MorphoStrategy(vaultAddr, asset, morpho, rmAddr);

        // 3. Self-grant vault-scoped GOVERNANCE. Signer must hold DEFAULT_ADMIN_ROLE (global admin
        //    of every scoped GOVERNANCE_ROLE). Leave in place; revoke separately to restore
        //    Timelock-only governance.
        bytes32 govRole = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        rm.grantRole(govRole, signer);

        // 4. Register the strategy (kind=1: ONCHAIN -> "DeFi" bucket) with configured target/caps.
        sm.addStrategy(address(strategy), 1, hasCfg ? c.morphoTargetBps : 0);
        bytes memory strategyIdData = abi.encode("MorphoStrategy", address(strategy));
        sm.increaseAbsoluteCap(strategyIdData, hasCfg ? c.morphoStrategyAbsCap : type(uint128).max);
        sm.increaseRelativeCap(strategyIdData, hasCfg ? c.morphoStrategyRelCap : WAD);
        if (hasCfg && c.forceDeallocatePenalty > 0) {
            sm.setForceDeallocatePenalty(address(strategy), c.forceDeallocatePenalty);
        }
        if (hasCfg && c.skimRecipient != address(0)) strategy.setSkimRecipient(c.skimRecipient);

        address irmAddr = irm;
        address collateralAddr = collateral;
        bytes32 marketId;
        bytes memory encodedMarketParams;
        bool configuredMarket; // any market was wired
        bool mockMarket; // true = mock/demo IRM+collateral; false = real (config) market

        // 5. Wire a market so the strategy can be allocated into.
        if (deployedMockMorpho || deployMockMarketComponents) {
            // Demo mode: deploy mock IRM + collateral (testnet).
            irmAddr = _deployMockIrm();
            collateralAddr = _deployMockCollateral();
            configuredMarket = true;
            mockMarket = true;
            (marketId, encodedMarketParams) = _configureTestMarket(vault, sm, strategy, collateralAddr, irmAddr);
        } else if (collateral != address(0) || irm != address(0)) {
            // Explicit mock IRM/collateral passed as args (testing an existing mock Morpho).
            require(collateral != address(0), "collateral required");
            require(irm != address(0), "irm required");
            configuredMarket = true;
            mockMarket = true;
            (marketId, encodedMarketParams) = _configureTestMarket(vault, sm, strategy, collateral, irm);
        } else if (hasCfg && c.morphoCollateralToken != address(0)) {
            // REAL market from config.morpho.{collateral,oracle,irm,lltv} + config caps.
            configuredMarket = true;
            mockMarket = false;
            irmAddr = c.morphoIrm;
            collateralAddr = c.morphoCollateralToken;
            (marketId, encodedMarketParams) = _configureRealMarket(vault, sm, strategy, c);
        }

        vm.stopBroadcast();

        console.log("=== MorphoStrategy deployed + wired ===");
        console.log("strategy        :", address(strategy));
        console.log("vault           :", vaultAddr);
        console.log("asset           :", asset);
        console.log("strategyManager :", smAddr);
        console.log("morpho          :", morpho, deployedMockMorpho ? "(fresh MorphoMock)" : "(from arg/config)");
        if (configuredMarket) {
            console.log(mockMarket ? "market type     : MOCK/demo" : "market type     : REAL (from config)");
            console.log(mockMarket ? "mockIrm         :" : "irm             :", irmAddr);
            console.log(mockMarket ? "mockCollateral  :" : "collateral      :", collateralAddr);
            console.log("marketId        :");
            console.logBytes32(marketId);
            console.log("encodedMarketParams:");
            console.logBytes(encodedMarketParams);
            console.log("To allocate into this market later, an ALLOCATOR runs:");
            console.log("  vault.allocate(strategy, <encodedMarketParams>, assets)");
        } else {
            console.log("no market wired: pass mock IRM/collateral, or set config.morpho.*");
            console.log("next steps (real market):");
            console.log("  1. strategy.setIrmApproved(realIrm, true)");
            console.log("  2. lift caps for the real collateral id");
            console.log("  3. lift caps for the real market id");
            console.log("  4. vault.allocate(strategy, abi.encode(realMarketParams), assets)");
        }
        console.log("");
        console.log("Restore Timelock-only governance later via:");
        console.log("  rm.revokeRole(rm.getScopedRole(vault, 'GOVERNANCE_ROLE'), signer)");
    }

    /// @dev Wires a REAL Morpho market from config.morpho params + config caps (mainnet path).
    function _configureRealMarket(Vault vault, StrategyManager sm, MorphoStrategy strategy, Config memory c)
        internal
        returns (bytes32 marketId, bytes memory encodedMarketParams)
    {
        strategy.setIrmApproved(c.morphoIrm, true);

        MarketParams memory mp = MarketParams({
            loanToken: vault.asset(),
            collateralToken: c.morphoCollateralToken,
            oracle: c.morphoOracle,
            irm: c.morphoIrm,
            lltv: c.morphoLltv
        });

        bytes memory collateralIdData = abi.encode("collateralToken", c.morphoCollateralToken);
        bytes memory marketIdData = abi.encode(address(strategy), Id.unwrap(mp.id()));
        sm.increaseAbsoluteCap(collateralIdData, c.morphoCollateralAbsCap);
        sm.increaseRelativeCap(collateralIdData, c.morphoCollateralRelCap);
        sm.increaseAbsoluteCap(marketIdData, c.morphoMarketAbsCap);
        sm.increaseRelativeCap(marketIdData, c.morphoMarketRelCap);

        encodedMarketParams = abi.encode(mp);
        marketId = Id.unwrap(mp.id());
    }

    function _configureTestMarket(
        Vault vault,
        StrategyManager sm,
        MorphoStrategy strategy,
        address collateral,
        address irm
    ) internal returns (bytes32 marketId, bytes memory encodedMarketParams) {
        strategy.setIrmApproved(irm, true);

        MarketParams memory mp = MarketParams({
            loanToken: vault.asset(),
            collateralToken: collateral,
            oracle: address(0),
            irm: irm,
            lltv: 0.86e18
        });

        bytes memory collateralIdData = abi.encode("collateralToken", collateral);
        bytes memory marketIdData = abi.encode(address(strategy), Id.unwrap(mp.id()));
        sm.increaseAbsoluteCap(collateralIdData, type(uint128).max);
        sm.increaseRelativeCap(collateralIdData, WAD);
        sm.increaseAbsoluteCap(marketIdData, type(uint128).max);
        sm.increaseRelativeCap(marketIdData, WAD);

        encodedMarketParams = abi.encode(mp);
        marketId = Id.unwrap(mp.id());
    }

    function _deployMockIrm() internal returns (address) {
        return address(new IrmMock());
    }

    function _deployMockCollateral() internal returns (address) {
        // WBTC-like decimals; MorphoMock does not validate collateral semantics.
        return address(new ERC20Mock(8));
    }
}
