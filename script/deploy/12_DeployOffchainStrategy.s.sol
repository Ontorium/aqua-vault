// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {OffchainNAVStrategy} from "../../src/strategies/OffchainNAVStrategy.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {StrategyManager} from "../../src/StrategyManager.sol";
import {Vault} from "../../src/Vault.sol";
import {WAD} from "../../src/libraries/ConstantsLib.sol";
import {EnvSigner} from "../EnvSigner.sol";
import {DeployConfig} from "../DeployConfig.sol";

/// @notice Step 12 — deploy an OffchainNAVStrategy for the given vault and wire it into the vault's
/// StrategyManager. Signer self-grants vault-scoped GOVERNANCE (admined by DEFAULT_ADMIN_ROLE),
/// registers the strategy as kind=2 (OFFCHAIN_NAV), and lifts its cap to max.
///
/// In production the strategy is used by the offchain manager (sends idle to custodian) and the
/// reporter (posts NAV updates). Both roles are scoped to the strategy address:
///   - scoped(strategy, OFFCHAIN_MANAGER)
///   - scoped(strategy, OFFCHAIN_REPORTER)
/// This script grants them to config.roles.offchainManager / offchainReporter (per-network config,
/// selected by chainid). Non-zero entries only; leave a config field at 0 to grant it manually later.
/// custodian likewise comes from CUSTODIAN env > config.external.custodian > signer (testnet).
///
/// Repeat once per vault: each vault needs its OWN strategy instance (vault + asset are immutable).
///
/// Args:
///   vault           Vault contract (its `asset()` is read to wire the strategy)
///   strategyManager Vault's StrategyManager
///   roleManager     Shared RoleManager
///
/// Required env: PRIVATE_KEY or MNEMONIC (signer must hold DEFAULT_ADMIN_ROLE).
/// Optional env:
///   CUSTODIAN            offchain custodian EOA. Defaults to signer (TESTNET ONLY; replace before mainnet).
///   STALE_PERIOD         max age of a NAV report before strategy falls back to onchain idle. Default 7 days.
///   MAX_CHANGE_BPS       max single-report NAV change in basis points (10000 = 100%). Default 1000 (10%).
///
/// Usage (USDT vault):
///   forge script script/deploy/12_DeployOffchainStrategy.s.sol \
///     --sig "run(address,address,address)" \
///     0xUSDTVault 0xUSDTStrategyManager 0xRoleManager \
///     --rpc-url arbitrum_sepolia --broadcast --verify
contract DeployOffchainStrategy is EnvSigner, DeployConfig {
    function run(address vaultAddr, address smAddr, address rmAddr) external {
        Vault vault = Vault(vaultAddr);
        address asset = vault.asset();
        RoleManager rm = RoleManager(rmAddr);
        StrategyManager sm = StrategyManager(smAddr);

        // Per-network config: custodian, stalePeriod, maxChangeBps, caps, operator role holders.
        bool hasCfg = _configAvailable();
        Config memory c;
        if (hasCfg) c = _loadConfig();

        // Knobs: env override > config value > DeployConfig default.
        address custodian = vm.envOr("CUSTODIAN", address(0));
        if (custodian == address(0)) custodian = c.custodian; // config.offchain.custodian, else signer below
        uint256 stalePeriod = vm.envOr("STALE_PERIOD", hasCfg ? c.stalePeriod : DEFAULT_STALE_PERIOD);
        uint256 maxChangeBps = vm.envOr("MAX_CHANGE_BPS", hasCfg ? c.maxChangeBps : DEFAULT_MAX_CHANGE_BPS);

        address signer = _startBroadcastFromEnv();
        if (custodian == address(0)) custodian = signer;

        // 1. Deploy strategy.
        OffchainNAVStrategy strategy = new OffchainNAVStrategy(
            vaultAddr, asset, rmAddr, custodian, stalePeriod, maxChangeBps
        );

        // 2. Self-grant vault-scoped GOVERNANCE so we can register + lift caps.
        bytes32 govRole = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        if (!rm.hasRole(govRole, signer)) rm.grantRole(govRole, signer);

        // 3. Register on SM (kind=2 = OFFCHAIN_NAV) with the configured target weight.
        sm.addStrategy(address(strategy), 2, hasCfg ? c.offchainTargetBps : 0);

        // 4. Lift the strategy's single id cap to max. OffchainNAVStrategy's id is
        //    keccak256(abi.encode(address(strategy), asset)) — must encode in that exact order to
        //    match `strategyId()`.
        bytes memory idData = abi.encode(address(strategy), asset);
        require(keccak256(idData) == strategy.strategyId(), "strategyId encoding mismatch");
        sm.increaseAbsoluteCap(idData, hasCfg ? c.offchainStrategyAbsCap : type(uint128).max);
        sm.increaseRelativeCap(idData, hasCfg ? c.offchainStrategyRelCap : WAD);

        // 5. Grant the offchain operator roles to the config holders (scoped to the strategy address).
        //    Admin of these roles is DEFAULT_ADMIN_ROLE, which the signer holds. Skipped if config is empty.
        if (c.offchainManager != address(0)) {
            rm.grantRole(rm.getScopedRole(address(strategy), "OFFCHAIN_MANAGER"), c.offchainManager);
        }
        if (c.offchainReporter != address(0)) {
            rm.grantRole(rm.getScopedRole(address(strategy), "OFFCHAIN_REPORTER"), c.offchainReporter);
        }

        // 6. Optional skim recipient (config.strategy.skimRecipient).
        if (hasCfg && c.skimRecipient != address(0)) strategy.setSkimRecipient(c.skimRecipient);

        vm.stopBroadcast();

        console.log("=== OffchainNAVStrategy deployed + wired ===");
        console.log("strategy             :", address(strategy));
        console.log("vault                :", vaultAddr);
        console.log("asset                :", asset);
        console.log("strategyManager      :", smAddr);
        console.log("custodian            :", custodian);
        console.log("stalePeriod (sec)    :", stalePeriod);
        console.log("maxChangeBps         :", maxChangeBps);
        console.log("offchainManager      :", c.offchainManager, c.offchainManager == address(0) ? "(not granted)" : "(granted)");
        console.log("offchainReporter     :", c.offchainReporter, c.offchainReporter == address(0) ? "(not granted)" : "(granted)");
    }
}
