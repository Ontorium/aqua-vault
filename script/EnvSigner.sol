// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {Script} from "../lib/forge-std/src/Script.sol";

/// @notice Resolves the broadcasting signer from the environment, supporting either a raw
/// PRIVATE_KEY or a MNEMONIC. Lets the deploy/report scripts run from a `.env` with whichever the
/// user prefers, while still falling back to a CLI-provided signer (--private-key/--mnemonic/--account).
abstract contract EnvSigner is Script {
    /// @dev Returns the signer private key from env, or 0 if none is set (caller should then rely on
    /// a CLI-provided signer). Precedence: PRIVATE_KEY (non-zero) > MNEMONIC (+ optional MNEMONIC_INDEX).
    function _envSignerKey() internal view returns (uint256 pk) {
        pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return pk;

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            pk = vm.deriveKey(mnemonic, uint32(vm.envOr("MNEMONIC_INDEX", uint256(0))));
        }
    }

    /// @dev Starts the broadcast as the env signer if available, otherwise as the CLI-provided signer.
    /// Returns the resolved signer address.
    function _startBroadcastFromEnv() internal returns (address signer) {
        uint256 pk = _envSignerKey();
        if (pk != 0) {
            signer = vm.addr(pk);
            vm.startBroadcast(pk);
        } else {
            signer = msg.sender;
            vm.startBroadcast();
        }
    }
}
