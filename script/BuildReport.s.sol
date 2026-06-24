// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {Script, console} from "../lib/forge-std/src/Script.sol";
import {stdJson} from "../lib/forge-std/src/StdJson.sol";

/// @notice Post-processing for LIVE report runs. Reads on-chain tx hashes from the broadcast log
/// and merges them with the header/body files. Two entry points:
///
///  - `run()` (default) — pairs with `IntegrationReport.s.sol`. Appends a single tx table.
///  - `buildScenario()` — pairs with `ScenarioReport.s.sol`. Patches `<!-- TX:name -->` markers in
///                        each test-case section with the matching call's tx hash, so every test
///                        case displays its own clickable tx link inline.
///
/// Usage:
///   forge script script/BuildReport.s.sol                          # IntegrationReport flow
///   forge script script/BuildReport.s.sol --sig "buildScenario()"  # ScenarioReport flow
/// Optional env: CHAIN_ID (defaults to 421614 = Arbitrum Sepolia).
contract BuildReport is Script {
    using stdJson for string;

    function run() external {
        uint256 chainId = vm.envOr("CHAIN_ID", uint256(421614));
        string memory runPath =
            string.concat("broadcast/IntegrationReport.s.sol/", vm.toString(chainId), "/run-latest.json");
        string memory json = vm.readFile(runPath);

        string memory explorer = chainId == 421614 ? "https://sepolia.arbiscan.io/tx/" : "";

        string memory table = "## Transactions\n\n| # | type | call | tx hash |\n|---:|---|---|---|\n";
        uint256 count;
        // Walk transactions[] by index; keyExistsJson never reverts, so it cleanly detects the end.
        while (vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(count), "].hash"))) {
            string memory base = string.concat(".transactions[", vm.toString(count), "]");
            string memory hash = json.readString(string.concat(base, ".hash"));
            string memory txType = _field(json, string.concat(base, ".transactionType"));
            // CALLs carry a decoded `function`; CREATEs carry `contractName` instead.
            string memory fn = _field(json, string.concat(base, ".function"));
            string memory call = bytes(fn).length > 0
                ? fn
                : string.concat("deploy ", _field(json, string.concat(base, ".contractName")));
            string memory hashCell =
                bytes(explorer).length == 0 ? hash : string.concat("[", hash, "](", explorer, hash, ")");
            count++;
            table = string.concat(table, "| ", vm.toString(count), " | ", txType, " | ", call, " | ", hashCell, " |\n");
        }
        table = string.concat(table, "\n");

        string memory header = vm.readFile("reports/_header.md");
        string memory body = vm.readFile("reports/_body.md");
        vm.writeFile("reports/integration-arbitrum-sepolia.md", string.concat(header, table, body));

        console.log("Wrote reports/integration-arbitrum-sepolia.md");
        console.log("Transactions merged:", count);
    }

    /// @dev Reads a string field, normalizing absent keys and JSON `null` to the empty string.
    function _field(string memory json, string memory key) internal view returns (string memory) {
        if (!vm.keyExistsJson(json, key)) return "";
        string memory v = json.readString(key);
        return keccak256(bytes(v)) == keccak256("null") ? "" : v;
    }

    /* ─────────────────────── ScenarioReport variant ─────────────────────── */

    /// @notice Patches each `<!-- TX:name -->` marker in the scenario body with the matching tx hash
    /// from the broadcast log. The mapping is by function-name → call ordering: e.g. the first call
    /// whose decoded function starts with "deposit(" fills `<!-- TX:deposit -->`.
    function buildScenario() external {
        uint256 chainId = vm.envOr("CHAIN_ID", uint256(421614));
        string memory runPath =
            string.concat("broadcast/ScenarioReport.s.sol/", vm.toString(chainId), "/run-latest.json");
        string memory json = vm.readFile(runPath);

        string memory explorer = chainId == 421614 ? "https://sepolia.arbiscan.io/tx/" : "";

        string memory body = vm.readFile("reports/_scenario_body.md");

        // Marker → broadcast-log function prefix. Order matters: first match in the broadcast log
        // wins. `time_skip` is a fork-only cheatcode with no live tx — marked __SKIP__.
        // NOTE: entries marked `__PLACEHOLDER__` exist purely to advance the skip counter for a
        // repeating prefix (no corresponding marker shown in the report markdown). Example: the
        // `deploy_to_custodian` scenario fires TWO txs (deployToCustodian + confirm report). The
        // scenario itself only displays the deployToCustodian hash, but the confirm `report(`
        // tx still consumes the 1st `report(` slot in the broadcast log — so subsequent
        // `nav_report_gain` / `return_from_custodian` lookups need to skip past it.
        string[23] memory markers = [
            "deposit_to_vault",
            "mint_to_vault",
            "allocate_to_aqua",
            "time_skip",
            "deallocate_from_aqua",
            "allocate_to_offchain",
            "deploy_to_custodian",
            "__placeholder_deploy_confirm__", // confirm report() inside _case_deployToCustodian
            "nav_report_gain",
            "return_from_custodian",
            "deallocate_from_offchain",
            "withdraw_immediate",
            "withdraw_queued",
            "redeem_with_yield",
            "inject_liquidity_for_claim",
            "claim_queued_withdrawal_deallocate",
            "claim_queued_withdrawal_fulfill",
            "claim_queued_withdrawal",
            "repay_exit_liquidity",
            // multi_user_claim_isolation fires 2 deposits + allocate + 2 redeems + deallocate +
            // fulfillWithdrawal + 2 claims. We surface the batch fulfill (main marker) and BOTH
            // per-account claims. These are the 2nd fulfillWithdrawal/claim occurrences (the user's
            // claim_queued_withdrawal consumed the 1st), so skip counting resolves them correctly.
            "multi_user_claim_isolation", // = the batch fulfillWithdrawal([A,B])
            "multi_user_claim_a", // = claim(A)
            "multi_user_claim_b", // = claim(B)
            "pause_unpause"
        ];
        string[23] memory prefixes = [
            "deposit(",
            "mint(",
            "allocate(",
            "__SKIP__",
            "deallocate(",
            "allocate(",
            "deployToCustodian(",
            "report(", // 1st report() = scenario 7's confirm
            "report(", // 2nd report() = scenario 8's NAV gain
            "report(", // 3rd report() = scenario 9's return report
            "deallocate(",
            "withdraw(",
            "withdraw(", // withdraw_queued = 2nd withdraw() in broadcast log
            "redeem(",
            "__SKIP__", // no-share liquidity feature removed; row left blank
            "deallocate(", // claim's deallocate = 3rd deallocate() (aqua, offchain, then claim's)
            "fulfillWithdrawal(",
            "claim(",
            "__SKIP__", // no-share liquidity feature removed; row left blank
            "fulfillWithdrawal(", // multi_user batch = 2nd fulfillWithdrawal()
            "claim(", // multi_user claim(A) = 2nd claim()
            "claim(", // multi_user claim(B) = 3rd claim()
            "pause("
        ];

        for (uint256 i; i < markers.length; ++i) {
            string memory marker = string.concat("<!-- TX:", markers[i], " -->");
            string memory cell;
            if (keccak256(bytes(prefixes[i])) == keccak256("__SKIP__")) {
                cell = unicode"_(포크 전용 - 온체인 tx 없음)_";
            } else {
                // For repeating prefixes (e.g. allocate/deallocate appear once for aqua, again for
                // offchain) take the Nth occurrence, where N = number of earlier markers using the
                // same prefix.
                uint256 skip;
                for (uint256 j; j < i; ++j) {
                    if (keccak256(bytes(prefixes[j])) == keccak256(bytes(prefixes[i]))) skip++;
                }
                string memory hash = _findNthHashByFunctionPrefix(json, prefixes[i], skip);
                if (bytes(hash).length == 0) {
                    cell = unicode"_(매칭되는 트랜잭션 없음)_";
                } else {
                    cell = bytes(explorer).length == 0 ? hash : string.concat("[", hash, "](", explorer, hash, ")");
                }
            }
            body = _replace(body, marker, cell);
        }

        string memory header = vm.readFile("reports/_scenario_header.md");
        vm.writeFile("reports/scenario-arbitrum-sepolia.md", string.concat(header, body));
        console.log("Wrote reports/scenario-arbitrum-sepolia.md");
    }

    function _findFirstHashByFunctionPrefix(string memory json, string memory prefix)
        internal
        view
        returns (string memory)
    {
        return _findNthHashByFunctionPrefix(json, prefix, 0);
    }

    /// @dev Returns the hash of the `skip`-th-then-next call (0 = first) whose decoded function
    /// starts with `prefix`. Used when the same prefix appears multiple times (allocate / deallocate
    /// fire once per strategy in the scenario report).
    function _findNthHashByFunctionPrefix(string memory json, string memory prefix, uint256 skip)
        internal
        view
        returns (string memory)
    {
        uint256 i;
        uint256 seen;
        while (vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(i), "].hash"))) {
            string memory base = string.concat(".transactions[", vm.toString(i), "]");
            string memory fn = _field(json, string.concat(base, ".function"));
            if (_startsWith(fn, prefix)) {
                if (seen == skip) return json.readString(string.concat(base, ".hash"));
                seen++;
            }
            i++;
        }
        return "";
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(prefix);
        if (sb.length < pb.length) return false;
        for (uint256 i; i < pb.length; ++i) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }

    /// @dev Replaces ALL occurrences of `needle` in `src`. Some markers (e.g.
    /// `<!-- TX:claim_queued_withdrawal -->`) appear multiple times — once inside the per-step
    /// breakdown and once on the main `**트랜잭션:**` line — and both must be patched.
    function _replace(string memory src, string memory needle, string memory repl)
        internal
        pure
        returns (string memory)
    {
        bytes memory n = bytes(needle);
        bytes memory r = bytes(repl);
        if (n.length == 0) return src;

        string memory out = src;
        // Loop until no more matches. Each pass replaces one occurrence; the result feeds the next.
        while (true) {
            bytes memory s = bytes(out);
            if (s.length < n.length) return out;

            uint256 idx = type(uint256).max;
            uint256 limit = s.length - n.length;
            for (uint256 i; i <= limit; ++i) {
                bool match_ = true;
                for (uint256 j; j < n.length; ++j) {
                    if (s[i + j] != n[j]) { match_ = false; break; }
                }
                if (match_) { idx = i; break; }
            }
            if (idx == type(uint256).max) return out;

            bytes memory next = new bytes(s.length - n.length + r.length);
            uint256 k;
            for (uint256 i; i < idx; ++i) next[k++] = s[i];
            for (uint256 i; i < r.length; ++i) next[k++] = r[i];
            for (uint256 i = idx + n.length; i < s.length; ++i) next[k++] = s[i];
            out = string(next);
        }
        revert("unreachable");
    }
}
