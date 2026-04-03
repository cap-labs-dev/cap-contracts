// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { CapIntegrationFixture } from "./CapIntegrationFixture.sol";

/// @dev Lender-focused fixture: deploy CAP, seed vault liquidity, and seed Symbiotic liquidity by default.
abstract contract LenderFixture is CapIntegrationFixture {
    uint256 internal constant DEFAULT_SYMBIOTIC_LIQUIDITY_NO_DECIMALS = 100;

    function _setUpLenderFixture() internal {
        _setUpCapWithUsdVaultAndSymbioticLiquidity(DEFAULT_SYMBIOTIC_LIQUIDITY_NO_DECIMALS);
    }
}

