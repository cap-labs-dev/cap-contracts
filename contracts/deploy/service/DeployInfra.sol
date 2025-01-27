// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessControl } from "../../access/AccessControl.sol";

import { Delegation } from "../../delegation/Delegation.sol";
import { Lender } from "../../lendingPool/Lender.sol";
import { Oracle } from "../../oracle/Oracle.sol";
import { ImplementationsConfig, InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";

contract DeployInfra is ProxyUtils {
    function _deployInfra(ImplementationsConfig memory implementations, UsersConfig memory users)
        internal
        returns (InfraConfig memory d)
    {
        // deploy proxy contracts
        d.accessControl = _proxy(implementations.accessControl);
        d.lender = _proxy(implementations.lender);
        d.oracle = _proxy(implementations.oracle);
        d.delegation = _proxy(implementations.delegation);

        // init infra instances
        AccessControl(d.accessControl).initialize(users.access_control_admin);
        uint256 targetHealth = 1e18;
        uint256 grace = 1 hours;
        uint256 expiry = block.timestamp + 1 hours;
        uint256 bonusCap = 1e18;
        Lender(d.lender).initialize(d.accessControl, d.delegation, d.oracle, targetHealth, grace, expiry, bonusCap);
        Oracle(d.oracle).initialize(d.accessControl);
        Delegation(d.delegation).initialize(d.accessControl, d.oracle);
    }
}
