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

/// @notice Step 13 — deploy a MOCK Morpho Blue (+IRM +collateral) and a MorphoStrategy for an
/// existing vault, then wire the strategy into the vault's StrategyManager. Mirrors step 9
/// (AquaStrategy) but for an onchain Morpho-supply strategy. Registers kind=1 (ONCHAIN) so it lands
/// in the "DeFi" allocation bucket alongside Aqua.
///
/// The signer self-grants the vault-scoped GOVERNANCE_ROLE (admined by DEFAULT_ADMIN_ROLE),
/// whitelists the mock IRM, adds the strategy, and lifts caps for ALL THREE ids the strategy emits
/// (strategy / collateral / market) so a later `vault.allocate` is not blocked by a zero cap.
///
/// Repeat once per vault: each vault needs its OWN MorphoStrategy instance (vault/asset are
/// immutable at construction). Re-running deploys a fresh mock Morpho — pass the SAME mock across
/// vaults only if you edit this script to take it as an arg.
///
/// A canonical demo market is fixed here:
///   MarketParams{ loanToken: vault.asset(), collateralToken: <mock>, oracle: 0, irm: <mock>, lltv: 0.86e18 }
/// The abi-encoded params are logged so an ALLOCATOR can later run:
///   vault.allocate(strategy, <encodedMarketParams>, assets)
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
        Vault vault = Vault(vaultAddr);
        address asset = vault.asset();
        RoleManager rm = RoleManager(rmAddr);
        StrategyManager sm = StrategyManager(smAddr);

        // Resolve Morpho: arg -> config.external.morpho -> (still 0) deploy a mock demo below.
        if (morpho == address(0) && _configAvailable()) morpho = _loadConfig().morpho;
        bool useMock = morpho == address(0);

        address signer = _startBroadcastFromEnv();

        // 1. When no real Morpho is given, deploy the mock protocol + a zero-rate IRM + mock collateral.
        IrmMock irm;
        ERC20Mock collateral;
        if (useMock) {
            morpho = address(new MorphoMock());
            irm = new IrmMock();
            collateral = new ERC20Mock(8); // WBTC-like; collateral is not validated by the mock.
        }

        // 2. Deploy the strategy bound to (vault, asset, morpho).
        MorphoStrategy strategy = new MorphoStrategy(vaultAddr, asset, morpho, rmAddr);

        // 3. Self-grant vault-scoped GOVERNANCE. Signer must hold DEFAULT_ADMIN_ROLE (global admin
        //    of every scoped GOVERNANCE_ROLE). Leave in place; revoke separately to restore
        //    Timelock-only governance.
        bytes32 govRole = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        rm.grantRole(govRole, signer);

        // 4. Register the strategy (kind=1: ONCHAIN -> "DeFi" bucket) and lift its strategy-level cap.
        sm.addStrategy(address(strategy), 1, 0);
        bytes memory strategyIdData = abi.encode("MorphoStrategy", address(strategy));
        sm.increaseAbsoluteCap(strategyIdData, type(uint128).max);
        sm.increaseRelativeCap(strategyIdData, WAD);

        // 5. Mock path only: whitelist the mock IRM and lift the demo market's collateral/market caps.
        //    For a real Morpho, an operator approves the real IRM and sets real market caps separately.
        MarketParams memory mp;
        if (useMock) {
            strategy.setIrmApproved(address(irm), true);
            mp = MarketParams({
                loanToken: asset,
                collateralToken: address(collateral),
                oracle: address(0),
                irm: address(irm),
                lltv: 0.86e18
            });
            bytes memory collateralIdData = abi.encode("collateralToken", address(collateral));
            bytes memory marketIdData = abi.encode(address(strategy), Id.unwrap(mp.id()));
            sm.increaseAbsoluteCap(collateralIdData, type(uint128).max);
            sm.increaseRelativeCap(collateralIdData, WAD);
            sm.increaseAbsoluteCap(marketIdData, type(uint128).max);
            sm.increaseRelativeCap(marketIdData, WAD);
        }

        vm.stopBroadcast();

        console.log("=== MorphoStrategy deployed + wired ===");
        console.log("strategy        :", address(strategy));
        console.log("vault           :", vaultAddr);
        console.log("asset           :", asset);
        console.log("strategyManager :", smAddr);
        console.log("morpho          :", morpho, useMock ? "(MOCK)" : "(real, from arg/config)");
        if (useMock) {
            console.log("mockIrm         :", address(irm));
            console.log("mockCollateral  :", address(collateral));
            console.log("marketId        :");
            console.logBytes32(Id.unwrap(mp.id()));
            console.log("To allocate idle funds into this demo market, an ALLOCATOR runs:");
            console.log("  vault.allocate(strategy, <encodedMarketParams>, assets)");
            console.log("encodedMarketParams:");
            console.logBytes(abi.encode(mp));
        } else {
            console.log("Real Morpho: approve the IRM and set market caps before allocating.");
        }
        console.log("");
        console.log("Restore Timelock-only governance later via:");
        console.log("  rm.revokeRole(rm.getScopedRole(vault, 'GOVERNANCE_ROLE'), signer)");
    }
}
