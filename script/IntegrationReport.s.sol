// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {Script, console} from "../lib/forge-std/src/Script.sol";
import {VmSafe} from "../lib/forge-std/src/Vm.sol";

import {Vault} from "../src/Vault.sol";
import {StrategyManager} from "../src/StrategyManager.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {StrategyMock} from "../test/mocks/StrategyMock.sol";
import {WAD} from "../src/libraries/ConstantsLib.sol";

interface IMintableERC20 {
    function mint(address to, uint256 value) external;
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice Exercises the deployed Aqua Vault stack against Arbitrum Sepolia and emits a Markdown
/// report with a before/after state table + description for every step.
///
/// Two modes, auto-detected via `vm.isContext`:
///   - Fork (no --broadcast): runs against a local fork of the RPC. Free, repeatable. No on-chain
///     tx hashes -> writes the complete report to reports/integration-fork.md.
///   - Live (--broadcast): sends real transactions. Writes reports/_header.md + reports/_body.md;
///     run script/BuildReport.s.sol afterwards to merge the real tx hashes from the broadcast log.
///
/// Required env: PRIVATE_KEY, VAULT, STRATEGY_MANAGER, ROLE_MANAGER, ASSET_ADDR.
/// Optional env: DEPOSIT_ASSETS, MINT_SHARES, ALLOCATE_ASSETS.
///
/// Usage:
///   set -a && source .env && set +a
///   mkdir -p reports
///   # fork:  forge script script/IntegrationReport.s.sol --rpc-url arbitrum_sepolia
///   # live:  forge script script/IntegrationReport.s.sol --rpc-url arbitrum_sepolia --broadcast
contract IntegrationReport is Script {
    Vault internal vault;
    StrategyManager internal sm;
    RoleManager internal rm;
    IMintableERC20 internal asset;
    StrategyMock internal strategy;

    address internal user;
    bool internal live;
    uint256 internal stepNo;
    string internal body; // accumulated step sections

    struct Snap {
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 sharePrice; // assets per 1e18 shares
        uint256 userShares;
        uint256 userAsset;
        uint256 vaultAsset;
        uint256 stratAsset;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        user = vm.addr(pk);

        vault = Vault(vm.envAddress("VAULT"));
        sm = StrategyManager(vm.envAddress("STRATEGY_MANAGER"));
        rm = RoleManager(vm.envAddress("ROLE_MANAGER"));
        asset = IMintableERC20(vm.envAddress("ASSET_ADDR"));

        uint256 depositAssets = vm.envOr("DEPOSIT_ASSETS", uint256(1_000_000));
        uint256 mintShares = vm.envOr("MINT_SHARES", uint256(500_000));
        uint256 allocAssets = vm.envOr("ALLOCATE_ASSETS", uint256(400_000));

        live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);

        vm.startBroadcast(pk);

        // 0. Self-grant operational roles. `user` must hold DEFAULT_ADMIN_ROLE (the deploy `owner`).
        Snap memory a = _snap();
        rm.grantRole(rm.GOVERNANCE_ROLE(), user);
        rm.grantRole(rm.ALLOCATOR_ROLE(), user);
        rm.grantRole(rm.SENTINEL_ROLE(), user);
        _step(
            "Grant operational roles",
            "Deployer (DEFAULT_ADMIN_ROLE) self-grants GOVERNANCE, ALLOCATOR and SENTINEL so a single EOA can drive the full flow without the Timelock.",
            a,
            _snap()
        );

        // 1. Fund + approve.
        a = _snap();
        asset.mint(user, depositAssets + mintShares + allocAssets + 1_000_000_000);
        asset.approve(address(vault), type(uint256).max);
        _step(
            "Mint underlying + approve vault",
            "Mint mock underlying to the deployer and grant the Vault an infinite allowance so deposits/mints can pull funds.",
            a,
            _snap()
        );

        // 2. deposit.
        a = _snap();
        uint256 mintedShares = vault.deposit(depositAssets, user);
        _step(
            string.concat("deposit(", vm.toString(depositAssets), ", self) -> ", vm.toString(mintedShares), " shares"),
            "Deposit underlying for vault shares. totalAssets and the deployer's share balance rise; the deployer's underlying balance drops by the deposited amount.",
            a,
            _snap()
        );

        // 3. mint.
        a = _snap();
        uint256 paid = vault.mint(mintShares, user);
        _step(
            string.concat("mint(", vm.toString(mintShares), " shares, self) costs ", vm.toString(paid)),
            "Mint an exact share amount, paying the previewed assets. Complements deposit() and confirms the share price is consistent in both directions.",
            a,
            _snap()
        );

        // 4. Deploy + register a strategy (GOVERNANCE), lift caps to max.
        a = _snap();
        strategy = new StrategyMock(address(vault), address(asset));
        sm.addStrategy(address(strategy), 1 /* STRATEGY_KIND_ONCHAIN */, 0, 0);
        sm.increaseAbsoluteCap(bytes("id-0"), type(uint128).max);
        sm.increaseAbsoluteCap(bytes("id-1"), type(uint128).max);
        sm.increaseRelativeCap(bytes("id-0"), WAD);
        sm.increaseRelativeCap(bytes("id-1"), WAD);
        _step(
            string.concat("Deploy + register StrategyMock ", vm.toString(address(strategy))),
            "Deploy an on-chain StrategyMock, register it via the StrategyManager and raise its absolute/relative caps to the maximum so allocate/deallocate run without cap clamping. No vault balances move yet.",
            a,
            _snap()
        );

        // 5. allocate.
        a = _snap();
        vault.allocate(address(strategy), hex"", allocAssets);
        _step(
            string.concat("allocate(strategy, ", vm.toString(allocAssets), ")"),
            "Move idle underlying from the Vault into the strategy. Vault underlying balance falls, strategy assets rise; totalAssets is unchanged (assets just relocated).",
            a,
            _snap()
        );

        // 6. deallocate.
        a = _snap();
        vault.deallocate(address(strategy), hex"", allocAssets);
        _step(
            string.concat("deallocate(strategy, ", vm.toString(allocAssets), ")"),
            "Pull the allocated underlying back into the Vault, restoring idle liquidity ahead of withdrawals.",
            a,
            _snap()
        );

        // 7. withdraw.
        uint256 wAssets = depositAssets / 5;
        a = _snap();
        uint256 burnedW = vault.withdraw(wAssets, user, user);
        _step(
            string.concat("withdraw(", vm.toString(wAssets), ", self, self) burns ", vm.toString(burnedW), " shares"),
            "Withdraw a fixed underlying amount to the deployer, burning the previewed shares. Served from idle liquidity restored by the deallocate above.",
            a,
            _snap()
        );

        // 8. redeem.
        uint256 rShares = vault.balanceOf(user) / 4;
        a = _snap();
        uint256 gotR = vault.redeem(rShares, user, user);
        _step(
            string.concat("redeem(", vm.toString(rShares), " shares, self, self) -> ", vm.toString(gotR)),
            "Burn a fixed share amount for the previewed underlying. The dual of withdraw(); confirms the share price round-trips.",
            a,
            _snap()
        );

        // 9. pause / unpause.
        a = _snap();
        vault.pause();
        vault.unpause();
        _step(
            "pause() then unpause()",
            "SENTINEL pauses (blocks deposits/mints) and GOVERNANCE unpauses. Exercises the emergency switch; balances are unaffected.",
            a,
            _snap()
        );

        // 10. accrueInterest.
        a = _snap();
        vault.accrueInterest();
        _step(
            "accrueInterest()",
            "Settle pending interest/fees into totalAssets and the share price. On a fresh deploy with no yield this is a no-op snapshot.",
            a,
            _snap()
        );

        vm.stopBroadcast();

        _write();
    }

    /* ---------------- snapshot + rendering ---------------- */

    function _snap() internal view returns (Snap memory s) {
        s.totalAssets = vault.totalAssets();
        s.totalSupply = vault.totalSupply();
        s.sharePrice = s.totalSupply == 0 ? 0 : vault.convertToAssets(1e18);
        s.userShares = vault.balanceOf(user);
        s.userAsset = asset.balanceOf(user);
        s.vaultAsset = asset.balanceOf(address(vault));
        s.stratAsset = address(strategy) == address(0) ? 0 : strategy.totalAssets();
    }

    function _step(string memory title, string memory desc, Snap memory b, Snap memory aft) internal {
        stepNo++;
        string memory t = string.concat("### Step ", vm.toString(stepNo), " - ", title, "\n\n", desc, "\n\n");
        t = string.concat(t, "| field | before | after | delta |\n|---|---:|---:|---:|\n");
        t = string.concat(t, _row("totalAssets", b.totalAssets, aft.totalAssets));
        t = string.concat(t, _row("totalSupply (shares)", b.totalSupply, aft.totalSupply));
        t = string.concat(t, _row("sharePrice (assets/1e18)", b.sharePrice, aft.sharePrice));
        t = string.concat(t, _row("user shares", b.userShares, aft.userShares));
        t = string.concat(t, _row("user underlying", b.userAsset, aft.userAsset));
        t = string.concat(t, _row("vault underlying", b.vaultAsset, aft.vaultAsset));
        t = string.concat(t, _row("strategy assets", b.stratAsset, aft.stratAsset));
        body = string.concat(body, t, "\n");
    }

    function _row(string memory name, uint256 b, uint256 a) internal pure returns (string memory) {
        int256 d = int256(a) - int256(b);
        return string.concat(
            "| ", name, " | ", vm.toString(b), " | ", vm.toString(a), " | ", vm.toString(d), " |\n"
        );
    }

    function _header() internal view returns (string memory) {
        string memory h = "# Aqua Vault - Integration Report\n\n";
        h = string.concat(h, "- Mode: ", live ? "**Live (Arbitrum Sepolia broadcast)**" : "**Fork simulation**", "\n");
        h = string.concat(h, "- Chain ID: ", vm.toString(block.chainid), "\n");
        h = string.concat(h, "- Block: ", vm.toString(block.number), "\n");
        h = string.concat(h, "- Actor (broadcaster): ", vm.toString(user), "\n");
        h = string.concat(h, "- Vault: ", vm.toString(address(vault)), "\n");
        h = string.concat(h, "- StrategyManager: ", vm.toString(address(sm)), "\n");
        h = string.concat(h, "- RoleManager: ", vm.toString(address(rm)), "\n");
        h = string.concat(h, "- Underlying: ", vm.toString(address(asset)), "\n");
        h = string.concat(h, "- Strategy (deployed this run): ", vm.toString(address(strategy)), "\n\n");
        return h;
    }

    function _write() internal {
        if (live) {
            // BuildReport.s.sol injects the on-chain tx table between header and body.
            vm.writeFile("reports/_header.md", _header());
            vm.writeFile("reports/_body.md", body);
            console.log("Wrote reports/_header.md + reports/_body.md. Now run script/BuildReport.s.sol.");
        } else {
            string memory note =
                "## Transactions\n\n_Fork simulation: calls were executed against a local fork, so there are no on-chain transaction hashes. Re-run with `--broadcast` against Arbitrum Sepolia and then `script/BuildReport.s.sol` to capture real hashes._\n\n";
            vm.writeFile("reports/integration-fork.md", string.concat(_header(), note, body));
            console.log("Wrote reports/integration-fork.md");
        }
    }
}
