// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Ontorium
pragma solidity ^0.8.28;

import {INAVHook} from "./INAVManager.sol";

interface IPriceManager is INAVHook {
    struct Metrics {
        uint128 netAssetValue;
        uint128 totalAssets;
        uint128 totalSupply;
        uint64 lastUpdate;
        uint256 pricePerShare;
    }

    function navUpdater() external view returns (address);
    function vault() external view returns (address);
    function offchainStrategy() external view returns (address);
    function metrics() external view returns (uint128, uint128, uint128, uint64, uint256);

    function pricePerShare() external view returns (uint256);
    function previewPricePerShare() external view returns (uint256);
}
