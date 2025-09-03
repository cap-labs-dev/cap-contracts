// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControl } from "../../../../access/AccessControl.sol";

import { CapSymbioticVaultFactory } from "../../../../delegation/providers/symbiotic/CapSymbioticVaultFactory.sol";

import { SymbioticAgentManager } from "../../../../delegation/providers/symbiotic/SymbioticAgentManager.sol";
import { SymbioticNetwork } from "../../../../delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkMiddleware } from "../../../../delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";

import { IDelegation } from "../../../../interfaces/IDelegation.sol";
import { IRateOracle } from "../../../../interfaces/IRateOracle.sol";

import { InfraConfig, UsersConfig } from "../../../interfaces/DeployConfigs.sol";

import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkAdapterImplementationsConfig,
    SymbioticNetworkAdapterParams,
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../../../interfaces/SymbioticsDeployConfigs.sol";
import { EigenAddressbook } from "../../../utils/EigenUtils.sol";

import {
    EigenServiceManager,
    IEigenServiceManager
} from "../../../../delegation/providers/eigenlayer/EigenServiceManager.sol";
import {
    EigenConfig,
    EigenImplementationsConfig,
    EigenUsersConfig,
    EigenVaultConfig
} from "../../../interfaces/EigenDeployConfig.sol";

import { ProxyUtils } from "../../../utils/ProxyUtils.sol";
import { SymbioticAddressbook } from "../../../utils/SymbioticUtils.sol";

import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";

import { IOperatorRegistry } from "@symbioticfi/core/src/interfaces/IOperatorRegistry.sol";
import { IDefaultStakerRewards } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";
import { IDefaultStakerRewardsFactory } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewardsFactory.sol";
import { console } from "forge-std/console.sol";

contract DeployCapNetworkAdapter is ProxyUtils {
    function _deploySymbioticNetworkAdapterImplems()
        internal
        returns (SymbioticNetworkAdapterImplementationsConfig memory d)
    {
        d.network = address(new SymbioticNetwork());
        d.networkMiddleware = address(new SymbioticNetworkMiddleware());
        d.agentManager = address(new SymbioticAgentManager());
    }

    function _deployEigenImplementations() internal returns (EigenImplementationsConfig memory d) {
        d.eigenServiceManager = address(new EigenServiceManager());
        //d.agentManager = address(new SymbioticAgentManager());
    }

    function _deployEigenInfra(
        InfraConfig memory infra,
        EigenImplementationsConfig memory implems,
        EigenAddressbook memory eigenAb,
        uint32 rewardDuration
    ) internal returns (EigenConfig memory d) {
        d.eigenServiceManager = _proxy(implems.eigenServiceManager);
        console.log("chainId: ", block.chainid);
        EigenServiceManager(d.eigenServiceManager).initialize(
            infra.accessControl,
            IEigenServiceManager.EigenAddresses({
                allocationManager: eigenAb.eigenAddresses.allocationManager,
                delegationManager: eigenAb.eigenAddresses.delegationManager,
                strategyManager: eigenAb.eigenAddresses.strategyManager,
                rewardsCoordinator: eigenAb.eigenAddresses.rewardsCoordinator
            }),
            infra.oracle,
            rewardDuration
        );
    }

    function _deploySymbioticNetworkAdapterInfra(
        address capToken,
        InfraConfig memory infra,
        SymbioticAddressbook memory addressbook,
        SymbioticNetworkAdapterImplementationsConfig memory implems,
        SymbioticNetworkAdapterParams memory params
    ) internal returns (SymbioticNetworkAdapterConfig memory d) {
        d.network = _proxy(address(implems.network));
        d.networkMiddleware = _proxy(address(implems.networkMiddleware));
        d.agentManager = _proxy(address(implems.agentManager));
        SymbioticNetwork(d.network).initialize(
            infra.accessControl,
            addressbook.registries.networkRegistry,
            addressbook.registries.operatorRegistry,
            addressbook.services.networkOptInService,
            addressbook.services.vaultOptInService,
            d.networkMiddleware,
            addressbook.services.networkMiddlewareService
        );
        SymbioticNetworkMiddleware(d.networkMiddleware).initialize(
            infra.accessControl,
            d.network,
            addressbook.registries.vaultRegistry,
            infra.oracle,
            params.vaultEpochDuration,
            params.feeAllowed
        );

        SymbioticAgentManager(d.agentManager).initialize(
            infra.accessControl, infra.lender, capToken, infra.delegation, d.networkMiddleware, infra.oracle
        );

        d.vaultFactory = address(
            new CapSymbioticVaultFactory(
                addressbook.services.vaultConfigurator,
                addressbook.factories.burnerRouterFactory,
                addressbook.factories.defaultStakerRewardsFactory,
                d.networkMiddleware
            )
        );
    }

    function _initSymbioticNetworkAdapterAccessControl(
        InfraConfig memory infra,
        SymbioticNetworkAdapterConfig memory adapter,
        UsersConfig memory users
    ) internal {
        SymbioticNetwork network = SymbioticNetwork(adapter.network);
        SymbioticNetworkMiddleware middleware = SymbioticNetworkMiddleware(adapter.networkMiddleware);
        SymbioticAgentManager agentManager = SymbioticAgentManager(adapter.agentManager);
        AccessControl accessControl = AccessControl(infra.accessControl);

        accessControl.grantAccess(middleware.registerVault.selector, address(middleware), address(agentManager));
        accessControl.grantAccess(middleware.setFeeAllowed.selector, address(middleware), users.middleware_admin);
        accessControl.grantAccess(middleware.slash.selector, address(middleware), infra.delegation);
        accessControl.grantAccess(middleware.distributeRewards.selector, address(middleware), infra.delegation);

        accessControl.grantAccess(network.registerVault.selector, address(network), address(middleware));
        accessControl.grantAccess(
            IDelegation(infra.delegation).addAgent.selector, infra.delegation, address(agentManager)
        );
        accessControl.grantAccess(
            IRateOracle(infra.oracle).setRestakerRate.selector, infra.oracle, address(agentManager)
        );
        accessControl.grantAccess(agentManager.addAgent.selector, address(agentManager), users.middleware_admin);
    }

    function _initEigenAccessControl(
        InfraConfig memory infra,
        EigenConfig memory adapter,
        address admin,
        EigenAddressbook memory eigenAb
    ) internal {
        EigenServiceManager eigenServiceManager = EigenServiceManager(adapter.eigenServiceManager);
        AccessControl accessControl = AccessControl(infra.accessControl);
        console.log("admin: ", admin);
        console.log("eigenServiceManager: ", address(eigenServiceManager));

        accessControl.grantAccess(eigenServiceManager.initialize.selector, address(eigenServiceManager), admin);
        accessControl.grantAccess(eigenServiceManager.registerStrategy.selector, address(eigenServiceManager), admin);
        accessControl.grantAccess(
            eigenServiceManager.registerOperator.selector,
            address(eigenServiceManager),
            eigenAb.eigenAddresses.allocationManager
        );
        accessControl.grantAccess(eigenServiceManager.slash.selector, address(eigenServiceManager), infra.delegation);
        accessControl.grantAccess(
            eigenServiceManager.distributeRewards.selector, address(eigenServiceManager), infra.delegation
        );
    }

    function _registerVaultInNetworkMiddleware(
        SymbioticNetworkAdapterConfig memory adapter,
        SymbioticVaultConfig memory vault,
        SymbioticNetworkRewardsConfig memory rewards,
        address agent
    ) internal {
        SymbioticNetworkMiddleware(adapter.networkMiddleware).registerVault(vault.vault, rewards.stakerRewarder, agent);
    }
}
