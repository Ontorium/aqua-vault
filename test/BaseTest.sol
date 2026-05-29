// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {Test, console} from "../lib/forge-std/src/Test.sol";
import {stdError} from "../lib/forge-std/src/StdError.sol";
import {StdStorage, stdStorage} from "../lib/forge-std/src/StdStorage.sol";

import {IVault} from "../src/interfaces/IVault.sol";
import {IVaultFactory} from "../src/interfaces/IVaultFactory.sol";
import {IStrategyManager} from "../src/interfaces/IStrategyManager.sol";
import {ITimelock} from "../src/interfaces/ITimelock.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

import {Vault} from "../src/Vault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {RoleManager} from "../src/RoleManager.sol";
import {StrategyManager} from "../src/StrategyManager.sol";
import {Timelock} from "../src/Timelock.sol";

import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {EventsLib} from "../src/libraries/EventsLib.sol";
import {MathLib} from "../src/libraries/MathLib.sol";
import "../src/libraries/ConstantsLib.sol";

import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {StrategyMock} from "./mocks/StrategyMock.sol";

abstract contract BaseTest is Test {
    using stdStorage for StdStorage;

    /// @dev Centralised actor labels reused across the test suite.
    address internal immutable owner = makeAddr("owner");
    address internal immutable governance = makeAddr("governance");
    address internal immutable curator = makeAddr("curator");
    address internal immutable sentinel = makeAddr("sentinel");
    address internal immutable allocator = makeAddr("allocator");

    uint256 internal underlyingTokenDecimals;

    ERC20Mock internal underlyingToken;
    VaultFactory internal vaultFactory;
    Vault internal vault;
    StrategyManager internal strategyManager;
    RoleManager internal roleManager;
    Timelock internal timelock;

    function setUp() public virtual {
        vm.label(address(this), "testContract");

        underlyingTokenDecimals = vm.envOr("DECIMALS", uint256(18));
        require(underlyingTokenDecimals <= 36, "decimals too high");
        underlyingToken = new ERC20Mock(uint8(underlyingTokenDecimals));
        vm.label(address(underlyingToken), "underlying");

        // ONE shared RoleManager (owner = DEFAULT_ADMIN_ROLE), then the factory bound to it. The factory
        // deploys only the Vault against that shared RoleManager and registers the vault's role scope.
        // StrategyManager, Timelock and all wiring are done here — mirroring script/Deploy.s.sol — because
        // the factory can no longer fit all the contracts under the EIP-170 code-size limit.
        roleManager = new RoleManager(owner);
        vaultFactory = new VaultFactory(address(roleManager));

        (address vAddr,) = vaultFactory.createVault(owner, address(underlyingToken), bytes32(0));
        vault = Vault(vAddr);

        strategyManager = new StrategyManager(vAddr, address(underlyingToken), address(roleManager));
        timelock = new Timelock(address(roleManager));
        // The Timelock is its own role scope; wire its GOVERNANCE->CURATOR/SENTINEL hierarchy.
        roleManager.registerScope(address(timelock));

        vm.label(address(vault), "vault");
        vm.label(address(strategyManager), "strategyManager");
        vm.label(address(roleManager), "roleManager");
        vm.label(address(timelock), "timelock");

        // Owner holds DEFAULT_ADMIN_ROLE. Grant the vault-scoped GOVERNANCE to the Timelock (production
        // wiring) and to a dedicated `governance` EOA (test ergonomics: lets tests call governance-gated
        // functions directly without going through the timelock). Also give `governance` the timelock's
        // own GOVERNANCE so it can configure the timelock and admin its crew.
        vm.startPrank(owner);
        roleManager.grantRole(roleManager.governanceRole(vAddr), address(timelock));
        roleManager.grantRole(roleManager.governanceRole(vAddr), governance);
        roleManager.grantRole(roleManager.governanceRole(address(timelock)), governance);
        vm.stopPrank();

        // GOVERNANCE wires the Vault -> StrategyManager (was the factory's job) and admins the rest.
        // Operational roles are granted in BOTH the vault scope (for vault/strategyManager gating) and the
        // timelock scope (so `curator`/`sentinel` can drive the shared Timelock in TimelockTest).
        vm.startPrank(governance);
        vault.setStrategyManager(address(strategyManager));
        roleManager.grantRole(roleManager.curatorRole(vAddr), curator);
        roleManager.grantRole(roleManager.sentinelRole(vAddr), sentinel);
        roleManager.grantRole(roleManager.allocatorRole(vAddr), allocator);
        roleManager.grantRole(roleManager.curatorRole(address(timelock)), curator);
        roleManager.grantRole(roleManager.sentinelRole(address(timelock)), sentinel);
        vm.stopPrank();
    }

    /* HELPERS */

    function _giveTokens(address to, uint256 amount) internal {
        underlyingToken.mint(to, amount);
    }

    /// @dev Caller must already own `assets` of underlying and have approved the vault.
    function _depositAs(address depositor, uint256 assets, address onBehalf) internal returns (uint256 shares) {
        vm.prank(depositor);
        shares = vault.deposit(assets, onBehalf);
    }

    function _grantRoleAs(address admin, bytes32 role, address account) internal {
        vm.prank(admin);
        roleManager.grantRole(role, account);
    }

    function _revokeRoleAs(address admin, bytes32 role, address account) internal {
        vm.prank(admin);
        roleManager.revokeRole(role, account);
    }

    /// @dev Wraps a governance-gated call through the live Timelock so paths that bypass `governance`
    /// (e.g. when verifying production wiring) can be exercised too.
    function _executeViaTimelock(address target, bytes memory data) internal returns (bytes memory) {
        vm.prank(curator);
        timelock.schedule(target, data);
        // Default timelock duration is zero unless explicitly set, so we can execute immediately.
        return timelock.execute(target, data);
    }

    /// @dev Slot of the packed `_totalAssets|lastUpdate|maxRate` tuple. Confirmed via
    /// `forge inspect Vault storage-layout`; assertions below catch any layout drift.
    bytes32 internal constant TOTAL_ASSETS_PACKED_SLOT = bytes32(uint256(12));

    /// @dev Stamps `_totalAssets` directly to simulate post-interest state in exchange-rate tests.
    /// Bypasses maxRate clamping so tests can probe arbitrary share prices.
    function _writeTotalAssets(uint256 newTotalAssets) internal {
        require(newTotalAssets <= type(uint128).max, "writeTotalAssets: overflow");
        bytes32 current = vm.load(address(vault), TOTAL_ASSETS_PACKED_SLOT);
        bytes32 mask = bytes32(uint256(type(uint128).max));
        bytes32 updated = (current & ~mask) | bytes32(newTotalAssets);
        vm.store(address(vault), TOTAL_ASSETS_PACKED_SLOT, updated);
        assertEq(uint256(vault._totalAssets()), newTotalAssets, "writeTotalAssets");
    }

    /// @dev Deploys a fresh strategy mock, registers it via governance, and lifts caps to the maximum
    /// so allocate/deallocate can run without cap noise. Returns the strategy address.
    function _addStrategyWithMaxCaps() internal returns (StrategyMock strategy) {
        strategy = new StrategyMock(address(vault), address(underlyingToken));
        vm.startPrank(governance);
        strategyManager.addStrategy(address(strategy), 1 /* STRATEGY_KIND_ONCHAIN */, 0, 0);
        strategyManager.increaseAbsoluteCap(bytes("id-0"), type(uint128).max);
        strategyManager.increaseAbsoluteCap(bytes("id-1"), type(uint128).max);
        strategyManager.increaseRelativeCap(bytes("id-0"), WAD);
        strategyManager.increaseRelativeCap(bytes("id-1"), WAD);
        vm.stopPrank();
    }
}

function min(uint256 a, uint256 b) pure returns (uint256) {
    return a < b ? a : b;
}
