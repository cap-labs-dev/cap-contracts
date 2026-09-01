// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { InterestRateModel } from "../../cap/InterestRateModel.sol";
import { Registry } from "../../cap/Registry.sol";
import { Stablecoin } from "../../cap/Stablecoin.sol";
import { IBeaconFactory } from "../../interfaces/IBeaconFactory.sol";
import { CapRoles } from "../../utils/CapRoles.sol";
import { InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";

contract ConfigureAccessControl {
    function _initInfraAccessControl(InfraConfig memory infra, UsersConfig memory users) internal {
        AccessManager manager = AccessManager(infra.accessManager);

        manager.grantRole(CapRoles.ADMIN, infra.registry, 0);
        manager.grantRole(CapRoles.REGISTRY, infra.registry, 0);
        manager.grantRole(CapRoles.GOVERNOR, users.governor, 0);
        manager.grantRole(CapRoles.KEEPER, users.keeper, 0);
        manager.grantRole(CapRoles.GUARDIAN, users.guardian, 0);
        manager.grantRole(CapRoles.ADMIN, users.admin, 0);
        manager.grantRole(CapRoles.LIQUIDATOR, users.liquidator, 0);

        bytes4[] memory factorySelectors = new bytes4[](1);
        factorySelectors[0] = IBeaconFactory.create.selector;
        manager.setTargetFunctionRole(infra.factory, factorySelectors, CapRoles.REGISTRY);

        bytes4[] memory governorSelectors = new bytes4[](1);
        governorSelectors[0] = Registry.assignOperator.selector;
        manager.setTargetFunctionRole(infra.registry, governorSelectors, CapRoles.GOVERNOR);

        bytes4[] memory keeperSelectors = new bytes4[](3);
        keeperSelectors[0] = Registry.createMarket.selector;
        keeperSelectors[1] = Registry.createFixedMarket.selector;
        keeperSelectors[2] = Registry.createUnderwriter.selector;
        manager.setTargetFunctionRole(infra.registry, keeperSelectors, CapRoles.KEEPER);

        bytes4[] memory minterSelectors = new bytes4[](2);
        minterSelectors[0] = Stablecoin.mintCreditBacked.selector;
        minterSelectors[1] = Stablecoin.burnCreditBacked.selector;
        manager.setTargetFunctionRole(infra.stablecoin, minterSelectors, CapRoles.MINTER);

        bytes4[] memory irmGovernorSelectors = new bytes4[](3);
        irmGovernorSelectors[0] = InterestRateModel.setLiquiditySlopes.selector;
        irmGovernorSelectors[1] = InterestRateModel.setTermMultiplierSlopes.selector;
        irmGovernorSelectors[2] = InterestRateModel.setLiquidationBonus.selector;
        manager.setTargetFunctionRole(infra.irm, irmGovernorSelectors, CapRoles.GOVERNOR);
    }
}
