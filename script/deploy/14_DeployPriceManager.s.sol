// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {PriceManager} from "../../src/PriceManager.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {EnvSigner} from "../EnvSigner.sol";

interface IOffchainView {
    function totalAssets() external view returns (uint256);
    function availableLiquidity() external view returns (uint256);
}

/// @notice Step 14 — deploy + wire the PriceManager so the vault's reported NAV can be synced
/// to its live value (`_realAssets()`) WITHOUT the `maxRate` growth cap.
///
/// Why this is needed: `Vault.syncReportedNAV()` is callable only by `priceManager`
/// ([Vault.sol] `require(msg.sender == priceManager)`). When `priceManager == address(0)` nobody
/// can call it, so `totalAssets()` only ever updates via `accrueInterest()` — which is clamped at
/// `maxRate` (100% APR preset). A live strategy NAV jump (e.g. a Morpho allocation) then stays
/// stuck behind the cap: reported NAV lags live NAV, weights exceed 100%, and APY reads ~the cap.
///
/// This script (run by the admin / mnemonic[0], which holds vault-scoped GOVERNANCE + DEFAULT_ADMIN):
///   1. deploys PriceManager(vault, offchainStrategy, roleManager)
///   2. vault.setPriceManager(pm)                                    — needs GOVERNANCE_ROLE
///   3. grants the PriceManager the (strategy-scoped) OFFCHAIN_REPORTER role
///      so its onUpdate() can call offchainStrategy.report()
///   4. grants the signer the (PriceManager-instance-scoped) NAV_UPDATER role so it can drive onUpdate()
///   5. runs one onUpdate() that re-reports the offchain strategy's CURRENT NAV (delta 0, a no-op
///      under maxChangeBps) and then syncs the vault → reported NAV jumps to live, gap closed.
///
/// In production, replace step 4/5's signer with a dedicated keeper EOA that calls
/// `pm.onUpdate(nav, liq, reportHash, reportURI)` on a schedule.
///
/// Args:
///   vault            Vault contract
///   offchainStrategy OffchainNAVStrategy bound to this vault
///   rm               shared RoleManager
///
/// Usage (USDT vault):
///   forge script script/deploy/14_DeployPriceManager.s.sol \
///     --sig "run(address,address,address)" \
///     0x55bf9D9276FfD80523b2417fA9a6A3242d1C9702 \
///     0xf336Fd4799f1CcD6dd18375C691c7D9eEFfCcE15 \
///     0xC395D30856E152A372aa2BD367A0e74fdA702bC0 \
///     --rpc-url arbitrum_sepolia --broadcast
///
/// Usage (OXAU vault): vault 0xa5E9…922a, offchain 0x56353da310A22603D1F75FB7e0c5c2Be40922563, same rm.
contract DeployPriceManager is EnvSigner {
    function run(address vaultAddr, address offchainStrategy, address rmAddr) external {
        IVault vault = IVault(vaultAddr);
        RoleManager rm = RoleManager(rmAddr);

        uint256 navBefore = vault.totalAssets();

        address signer = _startBroadcastFromEnv();

        // 1. Deploy the PriceManager (NAV_UPDATER scope = vault).
        PriceManager pm = new PriceManager(vault, offchainStrategy, rmAddr);

        // 2. Point the vault at it (GOVERNANCE_ROLE; signer self-grants if missing).
        bytes32 govRole = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        if (!rm.hasRole(govRole, signer)) rm.grantRole(govRole, signer);
        vault.setPriceManager(address(pm));

        // 3. Let the PriceManager report to the offchain strategy.
        //    NB: OFFCHAIN_REPORTER is scoped to the STRATEGY address on the deployed strategy.
        bytes32 reporterRole = rm.getScopedRole(offchainStrategy, "OFFCHAIN_REPORTER");
        if (!rm.hasRole(reporterRole, address(pm))) rm.grantRole(reporterRole, address(pm));

        // 4. Let the signer (keeper stand-in) drive onUpdate.
        //    NAV_UPDATER is scoped to the PriceManager INSTANCE (`_scopedRole` = keccak(address(pm), role)).
        bytes32 navUpdater = rm.getScopedRole(address(pm), "NAV_UPDATER");
        if (!rm.hasRole(navUpdater, signer)) rm.grantRole(navUpdater, signer);

        // 5. First sync: re-report the offchain strategy's CURRENT NAV (delta 0 → passes maxChangeBps),
        //    which triggers vault.syncReportedNAV() and credits the capped backlog in one shot.
        uint256 offchainNav = IOffchainView(offchainStrategy).totalAssets();
        uint256 offchainLiq = IOffchainView(offchainStrategy).availableLiquidity();
        pm.onUpdate(offchainNav, offchainLiq, bytes32(0), "");

        vm.stopBroadcast();

        uint256 navAfter = vault.totalAssets();

        console.log("=== PriceManager deployed & wired ===");
        console.log("priceManager      :", address(pm));
        console.log("vault             :", vaultAddr);
        console.log("offchainStrategy  :", offchainStrategy);
        console.log("signer/keeper     :", signer);
        console.log("reported NAV before:", navBefore);
        console.log("reported NAV after :", navAfter, "(now == live _realAssets, uncapped)");
    }
}
