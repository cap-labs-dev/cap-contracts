// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControl } from "../../../../access/AccessControl.sol";

import { IDelegation } from "../../../../interfaces/IDelegation.sol";
import { IRateOracle } from "../../../../interfaces/IRateOracle.sol";

import { InfraConfig } from "../../../interfaces/DeployConfigs.sol";
import { EigenAddressbook } from "../../../utils/EigenUtils.sol";

import { EigenAgentManager } from "../../../../delegation/providers/eigenlayer/EigenAgentManager.sol";
import {
    EigenServiceManager,
    IEigenServiceManager
} from "../../../../delegation/providers/eigenlayer/EigenServiceManager.sol";

import { EigenConfig, EigenImplementationsConfig } from "../../../interfaces/EigenDeployConfig.sol";

import { ProxyUtils } from "../../../utils/ProxyUtils.sol";

/// @dev Eigen adapter deployment + access-control wiring.
contract DeployEigenAdapter is ProxyUtils {
    /// @dev Deploys the Eigen proxy implementations (logic contracts).
    function _deployEigenImplementations() internal returns (EigenImplementationsConfig memory d) {
        d.eigenServiceManager = address(new EigenServiceManager());
        d.agentManager = address(new EigenAgentManager());
    }

    /// @dev Deploys + initializes the Eigen adapter proxies.
    /// `rewardDuration` is forwarded into `EigenServiceManager.initialize`.
    function _deployEigenInfra(
        InfraConfig memory infra,
        EigenImplementationsConfig memory implems,
        EigenAddressbook memory eigenAb,
        address cusd,
        uint32 rewardDuration
    ) internal returns (EigenConfig memory d) {
        d.eigenServiceManager = _proxy(implems.eigenServiceManager);
        d.agentManager = _proxy(implems.agentManager);

        EigenServiceManager(d.eigenServiceManager)
            .initialize(
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

        EigenAgentManager(d.agentManager)
            .initialize(infra.accessControl, infra.lender, cusd, infra.delegation, d.eigenServiceManager, infra.oracle);
    }

    /// @dev Grants minimal permissions so Eigen adapters can act through CAP's `AccessControl`.
    /// Expected call context: `access_control_admin`.
    function _initEigenAccessControl(
        InfraConfig memory infra,
        EigenConfig memory adapter,
        address admin,
        EigenAddressbook memory eigenAb
    ) internal {
        EigenServiceManager eigenServiceManager = EigenServiceManager(adapter.eigenServiceManager);
        AccessControl accessControl = AccessControl(infra.accessControl);

        accessControl.grantAccess(eigenServiceManager.initialize.selector, address(eigenServiceManager), admin);
        accessControl.grantAccess(
            eigenServiceManager.registerStrategy.selector, address(eigenServiceManager), adapter.agentManager
        );
        accessControl.grantAccess(
            eigenServiceManager.registerOperator.selector,
            address(eigenServiceManager),
            eigenAb.eigenAddresses.allocationManager
        );
        accessControl.grantAccess(eigenServiceManager.slash.selector, address(eigenServiceManager), infra.delegation);
        accessControl.grantAccess(
            eigenServiceManager.distributeRewards.selector, address(eigenServiceManager), infra.delegation
        );

        EigenAgentManager eigenAgentManager = EigenAgentManager(adapter.agentManager);
        accessControl.grantAccess(eigenAgentManager.addEigenAgent.selector, address(eigenAgentManager), admin);
        accessControl.grantAccess(eigenAgentManager.setRestakerRate.selector, address(eigenAgentManager), admin);
        accessControl.grantAccess(
            IRateOracle(infra.oracle).setRestakerRate.selector, infra.oracle, address(eigenAgentManager)
        );
        accessControl.grantAccess(
            IDelegation(infra.delegation).setCoverageCap.selector, infra.delegation, address(eigenAgentManager)
        );
        accessControl.grantAccess(
            IDelegation(infra.delegation).addAgent.selector, infra.delegation, address(eigenAgentManager)
        );
    }
}

