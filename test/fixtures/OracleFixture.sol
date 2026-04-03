// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { CapIntegrationFixture } from "./CapIntegrationFixture.sol";

/// @dev Oracle-focused fixture: deploy CAP and seed liquidity so oracle-derived prices are meaningful.
abstract contract OracleFixture is CapIntegrationFixture {
    function _setUpOracleFixture() internal {
        _setUpCapWithUsdVaultLiquidity();
    }
}

