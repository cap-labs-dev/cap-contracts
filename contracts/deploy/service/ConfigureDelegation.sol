// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Delegation } from "../../delegation/Delegation.sol";
import { DataTypes } from "../../delegation/libraries/types/DataTypes.sol";
import { InfraConfig } from "../interfaces/DeployConfigs.sol";

contract ConfigureDelegation {
    function _initDelegation(InfraConfig memory infra, address agent, address[] memory delegators) internal {
        Delegation(infra.delegation).addAgent(agent, DataTypes.AgentData({ ltv: 0.8e18, liquidationThreshold: 0.7e18 }));
        for (uint256 i = 0; i < delegators.length; i++) {
            Delegation(infra.delegation).registerDelegator(agent, delegators[i]);
        }
    }
}
