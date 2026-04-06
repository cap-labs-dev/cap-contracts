// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { CapIntegrationFixture } from "./CapIntegrationFixture.sol";

/// @dev Vault-focused fixture: deploy CAP and (optionally) seed vault liquidity.
abstract contract VaultFixture is CapIntegrationFixture {
    function _setUpVault() internal {
        _setUpCap();
    }

    function _setUpVaultWithLiquidity() internal {
        _setUpCapWithUsdVaultLiquidity();
    }
}

