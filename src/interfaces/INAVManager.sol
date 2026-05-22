// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

interface INAVHook {
    function onUpdate(uint256 netAssetValue, uint256 availableLiquidity, bytes32 reportHash, string calldata reportURI)
        external;
}
