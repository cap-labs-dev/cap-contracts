// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { Registry } from "../../../contracts/cap/Registry.sol";
import { IMigrator } from "../../../contracts/migration/IMigrator.sol";
import { Migrator } from "../../../contracts/migration/Migrator.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";

/// @title MigrateInfra
/// @notice Deploy the {Migrator} that moves the live cUSD and stcUSD proxies onto v2
/// @dev The runbook, and every check the migration enforces, are on {Migrator}.
contract MigrateInfra {
    /// @dev Deploy the migrator for the new implementations and infrastructure
    /// @param implementations The new implementation addresses
    /// @param infra The infrastructure, including the live token proxies and the new IRM
    /// @param users Token configuration (`stablecoinUnderlying`, `reserveVault`)
    /// @param feeReceiver The v1 FeeReceiver proxy
    /// @param executor The only account that may run the migration
    /// @return migrator The deployed migrator
    function _deployMigrator(
        ImplementationsConfig memory implementations,
        InfraConfig memory infra,
        UsersConfig memory users,
        address feeReceiver,
        address executor
    ) internal returns (Migrator migrator) {
        migrator = new Migrator(
            IMigrator.Config({
                executor: executor,
                upgrader: users.admin,
                stablecoin: infra.stablecoin,
                wrapper: infra.wrapper,
                feeReceiver: feeReceiver,
                stablecoinImplementation: implementations.stablecoin,
                wrapperImplementation: implementations.wrapper,
                authority: infra.accessManager,
                underlying: users.stablecoinUnderlying,
                irm: infra.irm,
                reserveVault: users.reserveVault,
                vestingPeriod: Registry(implementations.registry).DEFAULT_VESTING_PERIOD()
            })
        );
    }
}
