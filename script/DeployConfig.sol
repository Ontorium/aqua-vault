// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {Script} from "../lib/forge-std/src/Script.sol";

/// @notice Loads per-network deploy configuration from a JSON file under ./config, selected by
/// `block.chainid` (Aave-style). Keeps role-holder and integration addresses out of env/scripts so the
/// same scripts deploy to any network just by pointing at a different config file.
///
/// Resolution order:
///   1. CONFIG_FILE env var (explicit path, e.g. for anvil/local) — wins if set.
///   2. block.chainid -> config/<network>.json  (421614 = arbitrum_sepolia, 42161 = arbitrum).
///
/// Missing keys resolve to address(0); deploy scripts skip address(0) entries, so a config can be
/// filled in incrementally.
abstract contract DeployConfig is Script {
    struct Config {
        // Operational role holders (the deployer/owner is NOT here — it comes from the signer).
        address curator;
        address sentinel;
        address allocator;
        address offchainManager;
        address offchainReporter;
        // Fee recipients.
        address protocolFeeRecipient;
        address performanceFeeRecipient;
        address managementFeeRecipient;
        // External integration addresses (asset + protocol/custodian wiring).
        address asset;
        address aavePool;
        address aToken;
        address morpho;
        address custodian;
    }

    /// @dev Whether a config file is resolvable (CONFIG_FILE set, or a known chainid). Lets scripts read
    /// config only when present, so arg-only / local (anvil) deploys don't require a config file.
    function _configAvailable() internal view returns (bool) {
        if (bytes(vm.envOr("CONFIG_FILE", string(""))).length != 0) return true;
        uint256 id = block.chainid;
        return id == 421614 || id == 42161;
    }

    /// @dev Resolves the config file path for the current chain (or the CONFIG_FILE override).
    function _configPath() internal view returns (string memory) {
        string memory override_ = vm.envOr("CONFIG_FILE", string(""));
        if (bytes(override_).length != 0) return override_;

        uint256 id = block.chainid;
        if (id == 421614) return "config/arbitrum_sepolia.json";
        if (id == 42161) return "config/arbitrum.json";

        revert(
            string.concat("DeployConfig: no config for chainid ", vm.toString(id), " (set CONFIG_FILE to override)")
        );
    }

    /// @dev Reads and parses the network config into a struct.
    function _loadConfig() internal view returns (Config memory c) {
        string memory json = vm.readFile(_configPath());

        c.curator = _addr(json, ".roles.curator");
        c.sentinel = _addr(json, ".roles.sentinel");
        c.allocator = _addr(json, ".roles.allocator");
        c.offchainManager = _addr(json, ".roles.offchainManager");
        c.offchainReporter = _addr(json, ".roles.offchainReporter");

        c.protocolFeeRecipient = _addr(json, ".fees.protocolFeeRecipient");
        c.performanceFeeRecipient = _addr(json, ".fees.performanceFeeRecipient");
        c.managementFeeRecipient = _addr(json, ".fees.managementFeeRecipient");

        c.asset = _addr(json, ".external.asset");
        c.aavePool = _addr(json, ".external.aavePool");
        c.aToken = _addr(json, ".external.aToken");
        c.morpho = _addr(json, ".external.morpho");
        c.custodian = _addr(json, ".external.custodian");
    }

    /// @dev Parses an address at `key`, returning address(0) when the key is absent.
    function _addr(string memory json, string memory key) internal view returns (address) {
        if (!vm.keyExistsJson(json, key)) return address(0);
        return vm.parseJsonAddress(json, key);
    }
}
