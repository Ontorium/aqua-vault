// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../../lib/forge-std/src/Script.sol";
import {AquaStrategy} from "../../src/strategies/AquaStrategy.sol";
import {RoleManager} from "../../src/RoleManager.sol";
import {StrategyManager} from "../../src/StrategyManager.sol";
import {Vault} from "../../src/Vault.sol";
import {WAD} from "../../src/libraries/ConstantsLib.sol";
import {EnvSigner} from "../EnvSigner.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Step 10 — rotate (replace) the AquaStrategy registered on a vault's StrategyManager with
/// a freshly-deployed instance that includes the constructor `approve(_vault)` fix. Use this if you
/// already ran step 09 against a pre-fix strategy build and the live `deallocate` reverts with
/// `ERC20InsufficientAllowance`.
///
/// Flow:
///   1. Auto-discover the existing AquaStrategy on the StrategyManager (any registered strategy
///      that exposes an `aToken()` getter).
///   2. If its on-chain aToken balance exceeds its `writtenOff`, GOVERNANCE writes the difference
///      off so the strategy reports `totalAssets() == realAssets() == 0`. **NOTE**: the underlying
///      aTokens are NOT recovered — they remain orphaned at the old strategy address. This is
///      acceptable for testnet rotation; do not use this script verbatim in production without a
///      manual rescue step.
///   3. `removeStrategy(old)` clears it from the SM.
///   4. Deploy a NEW AquaStrategy (constructor now approves `_vault` per the fix) and `addStrategy`
///      it, lifting per-id caps to max for both the adapter and the aToken aggregate.
///
/// Args:
///   vault           Vault contract (asset is read from it)
///   lendingPool     Aqua / Aave-V2 lending pool
///   aToken          receipt aToken for the vault's asset on `lendingPool`
///   strategyManager Vault's StrategyManager (per-vault instance)
///   roleManager     Shared RoleManager
///
/// Required env: PRIVATE_KEY or MNEMONIC (signer must hold DEFAULT_ADMIN_ROLE).
///
/// Usage (USDT vault rotation):
///   forge script script/deploy/10_RotateAquaStrategy.s.sol \
///     --sig "run(address,address,address,address,address)" \
///     0xD408A6B5425e9866dc05F68F2c75e8F2F7495d95 \
///     0xd7105C76a995b8566e2DcC991FB4D8A13Ca6f816 \
///     0x6E6D0013A5c76131652Bc7282EEaC5536d8C2Ae3 \
///     0xe366037A8092A5159c19FfA9B30e6344dd412386 \
///     0x52815561C58731761DBfa302d0aE160712F7b331 \
///     --rpc-url arbitrum_sepolia --broadcast --verify
contract RotateAquaStrategy is EnvSigner {
    function run(
        address vaultAddr,
        address lendingPool,
        address aToken,
        address smAddr,
        address rmAddr
    ) external {
        Vault vault = Vault(vaultAddr);
        address asset = vault.asset();
        RoleManager rm = RoleManager(rmAddr);
        StrategyManager sm = StrategyManager(smAddr);

        address signer = _startBroadcastFromEnv();

        // 1. Self-grant GOVERNANCE so we can writeOff / removeStrategy / addStrategy / caps.
        bytes32 govRole = rm.getScopedRole(vaultAddr, "GOVERNANCE_ROLE");
        if (!rm.hasRole(govRole, signer)) rm.grantRole(govRole, signer);

        // 2. Discover existing AquaStrategy.
        address old = _findExistingAqua(sm);
        if (old != address(0)) {
            console.log("Found existing AquaStrategy:", old);
            _zeroOutAndRemove(sm, old, aToken);
        } else {
            console.log("No existing AquaStrategy registered. Skipping cleanup.");
        }

        // 3. Deploy + register fixed strategy.
        AquaStrategy newStrat = new AquaStrategy(vaultAddr, asset, lendingPool, aToken, rmAddr);
        sm.addStrategy(address(newStrat), 1 /* ONCHAIN */, 0, 0);

        bytes memory adapterIdData = abi.encode("AquaStrategy", address(newStrat));
        bytes memory aTokenIdData = abi.encode("aToken", aToken);
        sm.increaseAbsoluteCap(adapterIdData, type(uint128).max);
        sm.increaseRelativeCap(adapterIdData, WAD);
        sm.increaseAbsoluteCap(aTokenIdData, type(uint128).max);
        sm.increaseRelativeCap(aTokenIdData, WAD);

        vm.stopBroadcast();

        console.log("=== Rotation complete ===");
        console.log("new strategy    :", address(newStrat));
        console.log("vault           :", vaultAddr);
        console.log("asset           :", asset);
        console.log("aToken          :", aToken);
        console.log("strategyManager :", smAddr);
        if (old != address(0)) {
            console.log("");
            console.log("OLD STRATEGY (orphaned aTokens):", old);
        }
    }

    function _findExistingAqua(StrategyManager sm) internal view returns (address) {
        address[] memory list = sm.allStrategies();
        for (uint256 i; i < list.length; i++) {
            try AquaStrategy(list[i]).aToken() returns (address) {
                return list[i];
            } catch {}
        }
        return address(0);
    }

    function _zeroOutAndRemove(StrategyManager sm, address old, address aToken) internal {
        // removeStrategy requires `totalAssets() == 0` AND `realAssets() == 0`. Both follow once
        // writtenOff catches up to the aToken balance.
        uint256 aBal = IERC20Min(aToken).balanceOf(old);
        uint256 currentWO = AquaStrategy(old).writtenOff();
        if (aBal > currentWO) {
            uint256 delta = aBal - currentWO;
            AquaStrategy(old).writeOff(delta);
            console.log("Wrote off (aToken units):", delta);
        } else {
            console.log("Old strategy already has totalAssets == 0; no writeOff needed.");
        }

        sm.removeStrategy(old);
        console.log("Removed old strategy from SM.");
    }
}
