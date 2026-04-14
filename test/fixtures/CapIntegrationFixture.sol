// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { TestDeployer } from "../deploy/TestDeployer.sol";

/// @dev Common setup wrapper around `TestDeployer` so integration tests read consistently.
///
/// The default `TestDeployer` behavior is fork-first (unless the harness config selects mock mode).
/// These helpers intentionally keep that behavior and only reduce boilerplate in individual suites.
abstract contract CapIntegrationFixture is TestDeployer {
    function _setUpCap() internal {
        _deployCapTestEnvironment();
    }

    function _setUpCapWithUsdVaultLiquidity() internal {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
    }

    function _setUpCapWithUsdVaultAndSymbioticLiquidity(uint256 symbioticAmountNoDecimals) internal {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
        _initSymbioticVaultsLiquidity(env, symbioticAmountNoDecimals);
    }
}

