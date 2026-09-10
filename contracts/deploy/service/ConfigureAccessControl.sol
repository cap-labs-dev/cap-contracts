// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { CapRoles } from "../../utils/CapRoles.sol";
import { InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";

contract ConfigureAccessControl {
    /// @dev Grant protocol roles to the accounts that hold them. Function-to-role wiring lives on
    /// {Registry-initialize}; this step only says who is in each role.
    /// @param infra The deployed infrastructure addresses
    /// @param users The accounts receiving governor, keeper, guardian, admin and liquidator
    function _initInfraAccessControl(InfraConfig memory infra, UsersConfig memory users) internal {
        AccessManager manager = AccessManager(infra.accessManager);

        manager.grantRole(CapRoles.ADMIN, infra.registry, 0);
        manager.grantRole(CapRoles.REGISTRY, infra.registry, 0);
        manager.grantRole(CapRoles.GOVERNOR, users.governor, 0);
        manager.grantRole(CapRoles.KEEPER, users.keeper, 0);
        manager.grantRole(CapRoles.GUARDIAN, users.guardian, 0);
        manager.grantRole(CapRoles.ADMIN, users.admin, 0);
        manager.grantRole(CapRoles.LIQUIDATOR, users.liquidator, 0);
    }
}
