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

/// @notice Step 12 — deploy an OffchainNAVStrategy for the given vault and wire it into the vault's
/// StrategyManager. Signer self-grants vault-scoped GOVERNANCE (admined by DEFAULT_ADMIN_ROLE),
/// registers the strategy as kind=2 (OFFCHAIN_NAV), and lifts its cap to max.
///
/// In production the strategy is then used by the offchain manager (sends idle to custodian) and
/// the reporter (posts NAV updates). Both roles are scoped to the strategy address:
///   - scoped(strategy, OFFCHAIN_MANAGER)
///   - scoped(strategy, OFFCHAIN_REPORTER)
/// They are NOT granted by this script — assign them via the RoleManager once you know the operator
/// addresses.
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
///   MIN_REPORT_INTERVAL  rate-limit between reports. Default 1 hour.
///   MAX_CHANGE_BPS       max single-report NAV change in basis points (10000 = 100%). Default 1000 (10%).
///
/// Usage (USDT vault):
///   forge script script/deploy/12_DeployOffchainStrategy.s.sol \
///     --sig "run(address,address,address)" \
///     0xUSDTVault 0xUSDTStrategyManager 0xRoleManager \
///     --rpc-url arbitrum_sepolia --broadcast --verify
contract DeployOffchainStrategy is EnvSigner {
    function run(address vaultAddr, address smAddr, address rmAddr) external {
        Vault vault = Vault(vaultAddr);
        address asset = vault.asset();
        RoleManager rm = RoleManager(rmAddr);
        StrategyManager sm = StrategyManager(smAddr);

        // Knobs (with sensible testnet defaults).
        address custodian = vm.envOr("CUSTODIAN", address(0));
        uint256 stalePeriod = vm.envOr("STALE_PERIOD", uint256(7 days));
        uint256 minReportInterval = vm.envOr("MIN_REPORT_INTERVAL", uint256(1 hours));
        uint256 maxChangeBps = vm.envOr("MAX_CHANGE_BPS", uint256(1000)); // 10%

        address signer = _startBroadcastFromEnv();
        if (custodian == address(0)) custodian = signer;

        // 1. Deploy strategy.
        OffchainNAVStrategy strategy = new OffchainNAVStrategy(
            vaultAddr, asset, rmAddr, custodian, stalePeriod, minReportInterval, maxChangeBps
        );

        // 2. Self-grant vault-scoped GOVERNANCE so we can register + lift caps.
        bytes32 govRole = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        if (!rm.hasRole(govRole, signer)) rm.grantRole(govRole, signer);

        // 3. Register on SM (kind=2 = OFFCHAIN_NAV).
        sm.addStrategy(address(strategy), 2, 0);

        // 4. Lift the strategy's single id cap to max. OffchainNAVStrategy's id is
        //    keccak256(abi.encode(address(strategy), asset)) — must encode in that exact order to
        //    match `strategyId()`.
        bytes memory idData = abi.encode(address(strategy), asset);
        require(keccak256(idData) == strategy.strategyId(), "strategyId encoding mismatch");
        sm.increaseAbsoluteCap(idData, type(uint128).max);
        sm.increaseRelativeCap(idData, WAD);

        vm.stopBroadcast();

        console.log("=== OffchainNAVStrategy deployed + wired ===");
        console.log("strategy             :", address(strategy));
        console.log("vault                :", vaultAddr);
        console.log("asset                :", asset);
        console.log("strategyManager      :", smAddr);
        console.log("custodian            :", custodian);
        console.log("stalePeriod (sec)    :", stalePeriod);
        console.log("minReportInterval(s) :", minReportInterval);
        console.log("maxChangeBps         :", maxChangeBps);
        console.log("");
        console.log("Operator roles NOT granted; do so via RoleManager once you have addresses:");
        console.log("  rm.grantRole(scoped(strategy, 'OFFCHAIN_MANAGER'), <manager>)");
        console.log("  rm.grantRole(scoped(strategy, 'OFFCHAIN_REPORTER'), <reporter>)");
    }
}
