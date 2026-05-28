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

/// @notice Core deployment: a `VaultFactory` (which deploys the Vault + RoleManager), then the
/// StrategyManager + Timelock, wired up to mirror the original atomic factory.
///
/// Environment variables (signer):
///   PRIVATE_KEY        (optional) raw key for broadcasting; OR
///   MNEMONIC           (optional) seed phrase; uses MNEMONIC_INDEX (default 0).
///   If neither is set, falls back to the CLI signer (--private-key/--mnemonic/--account).
/// Other environment variables:
///   OWNER              (optional) DEFAULT_ADMIN_ROLE holder. Defaults to the signer. Must equal the
///                      signer for the wiring grants below to succeed.
///   ASSET              (optional) underlying ERC20. If unset, deploys a mintable MockToken (testnets only).
///   SALT               (optional) CREATE2 salt for the Vault address. Defaults to 0.
///   FACTORY            (optional) reuse an already-deployed VaultFactory instead of deploying a new one.
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast --verify
contract Deploy is EnvSigner {
    function run()
        external
        returns (
            address factory,
            address vault,
            address strategyManager,
            address roleManager,
            address timelock
        )
    {
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        address existingFactory = vm.envOr("FACTORY", address(0));

        // Signer from PRIVATE_KEY / MNEMONIC (see EnvSigner), or the CLI signer if neither is set.
        address deployer = _startBroadcastFromEnv();
        address owner = vm.envOr("OWNER", deployer);

        // 1. Underlying asset: use ASSET if provided, otherwise deploy a mock (testnet convenience).
        address asset = vm.envOr("ASSET", address(0));
        if (asset == address(0)) {
            asset = address(new MockToken("Mock USD", "mUSD", 6));
            console.log("WARNING: ASSET unset, deployed MockToken (testnet only):", asset);
        }

        // 2. Factory: reuse or deploy.
        VaultFactory f = existingFactory == address(0) ? new VaultFactory() : VaultFactory(existingFactory);
        factory = address(f);

        // 3. Factory deploys the Vault + its RoleManager (owner = DEFAULT_ADMIN_ROLE). The factory can
        //    no longer fit StrategyManager + Timelock under the EIP-170 24KB code-size limit, so we
        //    deploy and wire them here. The broadcaster must equal `owner` for the wiring grants below.
        (vault, roleManager) = f.createVault(owner, asset, salt);

        strategyManager = address(new StrategyManager(vault, asset, roleManager));
        timelock = address(new Timelock(roleManager));

        // 4. Wiring (was VaultFactory.createVault's job). owner holds DEFAULT_ADMIN_ROLE.
        RoleManager rm = RoleManager(roleManager);
        bytes32 GOVERNANCE_ROLE = rm.GOVERNANCE_ROLE();
        rm.grantRole(GOVERNANCE_ROLE, owner); // transient: lets owner set the StrategyManager
        Vault(vault).setStrategyManager(strategyManager);
        rm.grantRole(GOVERNANCE_ROLE, timelock); // Timelock becomes the standing governor
        rm.revokeRole(GOVERNANCE_ROLE, owner); // drop the transient grant (Timelock is sole governance)

        vm.stopBroadcast();

        console.log("== Aqua Vault deployment ==");
        console.log("deployer       :", deployer);
        console.log("owner (admin)  :", owner);
        console.log("asset          :", asset);
        console.log("VaultFactory   :", factory);
        console.log("Vault          :", vault);
        console.log("StrategyManager:", strategyManager);
        console.log("RoleManager    :", roleManager);
        console.log("Timelock       :", timelock);
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
