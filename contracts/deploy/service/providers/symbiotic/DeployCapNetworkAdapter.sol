// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControl } from "../../../../access/AccessControl.sol";

import { CapSymbioticVaultFactory } from "../../../../delegation/providers/symbiotic/CapSymbioticVaultFactory.sol";
import { SymbioticNetwork } from "../../../../delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkMiddleware } from "../../../../delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";

import { InfraConfig, UsersConfig } from "../../../interfaces/DeployConfigs.sol";
import {
    SymbioticNetworkAdapterConfig,
    SymbioticNetworkAdapterImplementationsConfig,
    SymbioticNetworkAdapterParams,
    SymbioticNetworkRewardsConfig,
    SymbioticVaultConfig
} from "../../../interfaces/SymbioticsDeployConfigs.sol";
import { ProxyUtils } from "../../../utils/ProxyUtils.sol";
import { SymbioticAddressbook } from "../../../utils/SymbioticUtils.sol";

import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";

import { IOperatorRegistry } from "@symbioticfi/core/src/interfaces/IOperatorRegistry.sol";
import { IDefaultStakerRewards } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";
import { IDefaultStakerRewardsFactory } from
    "@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewardsFactory.sol";

contract DeployCapNetworkAdapter is ProxyUtils {
    function _deploySymbioticNetworkAdapterImplems()
        internal
        returns (SymbioticNetworkAdapterImplementationsConfig memory d)
    {
        d.network = address(new SymbioticNetwork());
        d.networkMiddleware = address(new SymbioticNetworkMiddleware());
    }

    function _deploySymbioticNetworkAdapterInfra(
        InfraConfig memory infra,
        SymbioticAddressbook memory addressbook,
        SymbioticNetworkAdapterImplementationsConfig memory implems,
        SymbioticNetworkAdapterParams memory params
    ) internal returns (SymbioticNetworkAdapterConfig memory d) {
        d.network = _proxy(address(implems.network));
        d.networkMiddleware = _proxy(address(implems.networkMiddleware));
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
        AccessControl accessControl = AccessControl(infra.accessControl);

        accessControl.grantAccess(middleware.registerVault.selector, address(middleware), users.middleware_admin);
        accessControl.grantAccess(middleware.setFeeAllowed.selector, address(middleware), users.middleware_admin);
        accessControl.grantAccess(middleware.slash.selector, address(middleware), infra.delegation);
        accessControl.grantAccess(middleware.distributeRewards.selector, address(middleware), infra.delegation);

        accessControl.grantAccess(network.registerVault.selector, address(network), address(middleware));
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
