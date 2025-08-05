// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Delegation } from "../../delegation/Delegation.sol";
import { InfraConfig } from "../interfaces/DeployConfigs.sol";

contract ConfigureDelegation {
    function _registerNetworkForCapDelegation(InfraConfig memory infra, address network) internal {
        Delegation(infra.delegation).registerNetwork(network);
    }
}
