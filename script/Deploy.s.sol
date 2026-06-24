// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {console} from "../lib/forge-std/src/Script.sol";

import {VaultFactory} from "../src/VaultFactory.sol";
import {Vault} from "../src/Vault.sol";
import {StrategyManager} from "../src/StrategyManager.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {Timelock} from "../src/Timelock.sol";
import {EnvSigner} from "./EnvSigner.sol";

/// @notice Multi-vault governance topology: ONE shared RoleManager + ONE shared Timelock govern MANY
/// vaults. Roles are namespaced per scope inside the single RoleManager — each vault's GOVERNANCE/CURATOR/
/// SENTINEL/ALLOCATOR live under `getScopedRole(vault, ...)`, so operational roles stay isolated per vault even
/// though there is only one RoleManager. The shared Timelock governs a vault by holding `scoped(vault,
/// GOVERNANCE)` (Timelock.execute does target.call, and vault governance functions check the scoped role);
/// the Timelock's own crew (configure targets / schedule / revoke) lives under `scoped(timelock, ...)`.
///
/// Signer comes from the environment (PRIVATE_KEY or MNEMONIC + optional MNEMONIC_INDEX; see EnvSigner),
/// or the CLI signer (--private-key/--mnemonic/--account) if neither is set. OWNER (optional env) is the
/// admin / governance-crew holder, defaulting to the signer; it MUST equal the signer for the grants to
/// succeed. In production, hand OWNER's roles to a multisig.
///
/// Two-phase usage (run governance ONCE, then a vault per asset):
///   # 1) governance singletons (record the two printed addresses)
///   forge script script/Deploy.s.sol:Deploy --sig "deployGovernance()" --rpc-url $RPC --broadcast
///   # 2) a vault wired to the shared timelock (timelock, factory, asset, salt, symbol, name)
///   forge script script/Deploy.s.sol:Deploy \
///     --sig "deployVault(address,address,address,bytes32,string,string)" \
///     <TIMELOCK> 0x0 0x0 0x0 "aquavUSDT" "Aqua Vault USDT" --rpc-url $RPC --broadcast
/// Or `run(...)` to bootstrap governance + the first vault in one command.
contract Deploy is EnvSigner {
    /// @dev OWNER env (empty -> deployer) is the governance-crew / admin holder.
    function _owner(address deployer) internal view returns (address) {
        string memory ownerEnv = vm.envOr("OWNER", string(""));
        return bytes(ownerEnv).length == 0 ? deployer : vm.parseAddress(ownerEnv);
    }

    /* ── ENTRYPOINTS ──────────────────────────────────────────────────────────── */

    /// @notice Deploy the shared governance singletons ONCE: a dedicated governance RoleManager and the
    /// shared Timelock bound to it. `owner` becomes the crew that drives the Timelock (GOVERNANCE to
    /// configure targets, CURATOR to schedule, SENTINEL to revoke).
    function deployGovernance() external returns (address govRoleManager, address timelock) {
        address owner = _owner(_startBroadcastFromEnv());
        (govRoleManager, timelock) = _deployGovernance(owner);
        vm.stopBroadcast();

        console.log("== Aqua governance ==");
        console.log("owner (gov crew):", owner);
        console.log("govRoleManager  :", govRoleManager);
        console.log("Timelock        :", timelock);
    }

    /// @notice Deploy one vault wired to an existing shared `timelock`. `factory`/`asset` of 0 deploy a
    /// fresh one (asset 0 -> mintable MockToken, testnet only). The signer must hold GOVERNANCE on the
    /// timelock's governance RoleManager (granted by {deployGovernance}) to register the new targets.
    function deployVault(
        address timelock,
        address factory,
        address asset,
        bytes32 salt,
        string memory symbol,
        string memory name
    ) external returns (address vaultFactory, address vault, address strategyManager, address roleManager) {
        address owner = _owner(_startBroadcastFromEnv());
        (vaultFactory, vault, strategyManager, roleManager) =
            _deployVault(Timelock(timelock), owner, factory, asset, salt, symbol, name);
        vm.stopBroadcast();
        _logVault(owner, asset, vaultFactory, vault, strategyManager, roleManager, timelock);
    }

    /// @notice Convenience: bootstrap governance + the first vault in one transaction batch.
    function run(address asset, bytes32 salt, address factory, string memory symbol, string memory name)
        external
        returns (
            address vaultFactory,
            address vault,
            address strategyManager,
            address roleManager,
            address timelock
        )
    {
        address owner = _owner(_startBroadcastFromEnv());
        address govRoleManager;
        (govRoleManager, timelock) = _deployGovernance(owner);
        (vaultFactory, vault, strategyManager, roleManager) =
            _deployVault(Timelock(timelock), owner, factory, asset, salt, symbol, name);
        vm.stopBroadcast();

        console.log("govRoleManager :", govRoleManager);
        _logVault(owner, asset, vaultFactory, vault, strategyManager, roleManager, timelock);
    }

    /* ── INTERNAL (no broadcast management) ───────────────────────────────────── */

    function _deployGovernance(address owner) internal returns (address govRoleManager, address timelock) {
        RoleManager rm = new RoleManager(owner); // owner = DEFAULT_ADMIN_ROLE (the single shared RoleManager)
        Timelock tl = new Timelock(address(rm));

        // The Timelock is its own role scope. Wire its GOVERNANCE→CURATOR/SENTINEL hierarchy, then give
        // `owner` the crew roles so it can drive the Timelock (configure targets / schedule / revoke).
        // owner is DEFAULT_ADMIN, so it can grant itself the scoped GOVERNANCE, which then admins CURATOR/SENTINEL.
        rm.registerScope(address(tl));
        rm.grantRole(rm.getScopedRole(address(tl), "GOVERNANCE_ROLE"), owner);
        rm.grantRole(rm.getScopedRole(address(tl), "CURATOR_ROLE"), owner);
        rm.grantRole(rm.getScopedRole(address(tl), "SENTINEL_ROLE"), owner);

        govRoleManager = address(rm);
        timelock = address(tl);
    }

    function _deployVault(
        Timelock timelock,
        address owner,
        address factory,
        address asset,
        bytes32 salt,
        string memory symbol,
        string memory name
    ) internal returns (address vaultFactory, address vault, address strategyManager, address roleManager) {
        // Underlying: provided token, else a mock (testnet convenience).
        if (asset == address(0)) {
            asset = address(new MockToken("Mock USD", "mUSD", 6));
            console.log("WARNING: asset is zero, deployed MockToken (testnet only):", asset);
        }

        // The single shared RoleManager backing this deployment (the Timelock points to it).
        RoleManager rm = RoleManager(address(timelock.roleManager()));
        VaultFactory f = factory == address(0) ? new VaultFactory() : VaultFactory(factory);
        vaultFactory = address(f);

        // Factory deploys the Vault against the shared RoleManager and registers the vault's role scope.
        roleManager = address(rm);
        vault = f.createVault(roleManager, owner, asset, salt);
        strategyManager = address(new StrategyManager(vault, asset, roleManager));

        // Wire the vault: owner (DEFAULT_ADMIN) transiently takes the vault-scoped GOVERNANCE to do the setup,
        // then hands it to the SHARED Timelock (the standing governor for this vault).
        bytes32 governanceRole = rm.getScopedRole(vault, "GOVERNANCE_ROLE");
        rm.grantRole(governanceRole, owner);
        Vault(vault).setStrategyManager(strategyManager);
        if (bytes(name).length != 0) Vault(vault).setName(name);
        if (bytes(symbol).length != 0) Vault(vault).setSymbol(symbol);
        rm.grantRole(governanceRole, address(timelock));
        rm.revokeRole(governanceRole, owner);

        // Register the new contracts as governance targets on the shared Timelock so it can govern them.
        // Requires the signer to hold GOVERNANCE on the Timelock's governance RoleManager.
        timelock.setIsTarget(vault, true);
        timelock.setIsTarget(strategyManager, true);
    }

    function _logVault(
        address owner,
        address asset,
        address vaultFactory,
        address vault,
        address strategyManager,
        address roleManager,
        address timelock
    ) internal view {
        console.log("== Aqua Vault deployment ==");
        console.log("owner (admin)  :", owner);
        console.log("asset          :", asset);
        console.log("share name     :", Vault(vault).name());
        console.log("share symbol   :", Vault(vault).symbol());
        console.log("VaultFactory   :", vaultFactory);
        console.log("Vault          :", vault);
        console.log("StrategyManager:", strategyManager);
        console.log("RoleManager    :", roleManager);
        console.log("Timelock(shared):", timelock);
    }
}

/// @dev Minimal mintable token for testnet deploys when no real ASSET is supplied. Not for mainnet.
contract MockToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }
}
