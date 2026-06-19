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
/// (adapter / collateral / market) so a later `vault.allocate` is not blocked by a zero cap.
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
///
/// Required env: PRIVATE_KEY or MNEMONIC (signer must hold DEFAULT_ADMIN_ROLE on RoleManager).
///
/// Usage (USDT vault):
///   forge script script/deploy/13_DeployMorphoStrategy.s.sol \
///     --sig "run(address,address,address)" \
///     0x55bf9D9276FfD80523b2417fA9a6A3242d1C9702 \
///     0x535D25d2691B0933a5e1E2eE48feFacAD3b317eD \
///     0xC395D30856E152A372aa2BD367A0e74fdA702bC0 \
///     --rpc-url arbitrum_sepolia --broadcast
contract DeployMorphoStrategy is EnvSigner {
    using MarketParamsLib for MarketParams;

    function run(address vaultAddr, address smAddr, address rmAddr) external {
        Vault vault = Vault(vaultAddr);
        address asset = vault.asset();
        RoleManager rm = RoleManager(rmAddr);
        StrategyManager sm = StrategyManager(smAddr);

        address signer = _startBroadcastFromEnv();

        // 1. Deploy the mock Morpho Blue protocol, a zero-rate IRM, and a mock collateral token.
        MorphoMock morpho = new MorphoMock();
        IrmMock irm = new IrmMock();
        ERC20Mock collateral = new ERC20Mock(8); // WBTC-like; collateral is not validated by the mock.

        // 2. Deploy the strategy bound to (vault, asset, morpho).
        MorphoStrategy strategy = new MorphoStrategy(vaultAddr, asset, address(morpho), rmAddr);

        // 3. Self-grant vault-scoped GOVERNANCE. Signer must hold DEFAULT_ADMIN_ROLE (global admin
        //    of every scoped GOVERNANCE_ROLE). Leave in place; revoke separately to restore
        //    Timelock-only governance.
        bytes32 govRole = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        rm.grantRole(govRole, signer);

        // 4. Whitelist the mock IRM (allocate reverts on an unapproved IRM).
        strategy.setIrmApproved(address(irm), true);

        // 5. Register the strategy (kind=1: ONCHAIN -> "DeFi" bucket).
        sm.addStrategy(address(strategy), 1, 0, 0);

        // 6. Lift caps for the three ids emitted by `MorphoStrategy._ids` for the canonical market.
        //    All three must permit flow or `allocate()` reverts on the smallest.
        MarketParams memory mp = MarketParams({
            loanToken: asset,
            collateralToken: address(collateral),
            oracle: address(0),
            irm: address(irm),
            lltv: 0.86e18
        });

        bytes memory adapterIdData = abi.encode("MorphoStrategy", address(strategy));
        bytes memory collateralIdData = abi.encode("collateralToken", address(collateral));
        bytes memory marketIdData = abi.encode(address(strategy), Id.unwrap(mp.id()));

        sm.increaseAbsoluteCap(adapterIdData, type(uint128).max);
        sm.increaseRelativeCap(adapterIdData, WAD);
        sm.increaseAbsoluteCap(collateralIdData, type(uint128).max);
        sm.increaseRelativeCap(collateralIdData, WAD);
        sm.increaseAbsoluteCap(marketIdData, type(uint128).max);
        sm.increaseRelativeCap(marketIdData, WAD);

        vm.stopBroadcast();

        bytes memory encodedMarketParams = abi.encode(mp);

        console.log("=== MorphoStrategy deployed + wired ===");
        console.log("strategy        :", address(strategy));
        console.log("vault           :", vaultAddr);
        console.log("asset           :", asset);
        console.log("strategyManager :", smAddr);
        console.log("mockMorpho      :", address(morpho));
        console.log("mockIrm         :", address(irm));
        console.log("mockCollateral  :", address(collateral));
        console.log("marketId        :");
        console.logBytes32(Id.unwrap(mp.id()));
        console.log("");
        console.log("To allocate idle funds into this market, an ALLOCATOR runs:");
        console.log("  vault.allocate(strategy, <encodedMarketParams>, assets)");
        console.log("encodedMarketParams:");
        console.logBytes(encodedMarketParams);
        console.log("");
        console.log("Restore Timelock-only governance later via:");
        console.log("  rm.revokeRole(rm.getScopedRole(vault, 'GOVERNANCE_ROLE'), signer)");
    }
}
