// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Delegation } from "../../delegation/Delegation.sol";
import { DataTypes } from "../../delegation/libraries/types/DataTypes.sol";
import { InfraConfig } from "../interfaces/DeployConfigs.sol";

contract ConfigureDelegation {
    function _initDelegationAgent(InfraConfig memory infra, address agent) internal {
        Delegation(infra.delegation).addAgent(agent, DataTypes.AgentData({ ltv: 0.8e18, liquidationThreshold: 0.7e18 }));
    }

    function _initDelegationAgentDelegator(InfraConfig memory infra, address agent, address delegator) internal {
        Delegation(infra.delegation).registerNetwork(agent, delegator);
    }
}
