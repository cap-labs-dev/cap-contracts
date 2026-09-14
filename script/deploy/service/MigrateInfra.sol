// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../contracts/cap/Wrapper.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title MigrateInfra
/// @notice Upgrade the live cUSD and stcUSD proxies onto the v2 implementations
/// @dev Caller must already be allowed to `upgradeToAndCall` on the v1 AccessControl.
contract MigrateInfra {
    /// @dev Point the live proxies at the new implementations and run `reinitializer(2)`.
    ///      cUSD first: the wrapper initializer opts into the new vest, which only exists
    ///      after cUSD has been upgraded.
    /// @param implementations The new implementation addresses
    /// @param infra The infrastructure, including the live token proxies and the new IRM
    /// @param users Token configuration (`stablecoinUnderlying`, `reserveVault`)
    /// @param name Live cUSD name, so the ERC-2612 domain does not move
    /// @param symbol Live cUSD symbol
    function _upgradeExistingTokens(
        ImplementationsConfig memory implementations,
        InfraConfig memory infra,
        UsersConfig memory users,
        string memory name,
        string memory symbol
    ) internal {
        UUPSUpgradeable(infra.stablecoin)
            .upgradeToAndCall(
                implementations.stablecoin,
                abi.encodeCall(
                    Stablecoin.initialize,
                    (infra.accessManager, users.stablecoinUnderlying, name, symbol, infra.irm, users.reserveVault)
                )
            );
        UUPSUpgradeable(infra.wrapper)
            .upgradeToAndCall(
                implementations.wrapper, abi.encodeCall(Wrapper.initialize, (infra.accessManager, infra.stablecoin))
            );
    }
}
