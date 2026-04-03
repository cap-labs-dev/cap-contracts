// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { CapIntegrationFixture } from "../fixtures/CapIntegrationFixture.sol";

/// @dev Manual/experimental suite for reasoning about stake exposure across Symbiotic vault epochs.
/// Intentionally contains no active `test*` functions (keep this file as a sandbox without breaking CI).
contract MiddlewareCollateralManual is CapIntegrationFixture {
    function setUp() public {
        _setUpCap();
        _initSymbioticVaultsLiquidity(env, 100);

        // reset the initial stakes for this test
        {
            _timeTravel(symbioticWethVault.vaultEpochDuration + 1 days);
        }
    }
}
