// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControl } from "../../access/AccessControl.sol";

import { Delegation } from "../../delegation/Delegation.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { Lender } from "../../lendingPool/Lender.sol";
import { InfraConfig, UsersConfig } from "../interfaces/DeployConfigs.sol";

contract ConfigureAccessControl {
    function _initInfraAccessControl(InfraConfig memory infra, UsersConfig memory users) internal {
        AccessControl accessControl = AccessControl(infra.accessControl);
        accessControl.grantAccess(IOracle.setPriceOracleData.selector, infra.oracle, users.oracle_admin);
        accessControl.grantAccess(IOracle.setPriceBackupOracleData.selector, infra.oracle, users.oracle_admin);

        accessControl.grantAccess(IOracle.setBenchmarkRate.selector, infra.oracle, users.rate_oracle_admin);
        accessControl.grantAccess(IOracle.setRestakerRate.selector, infra.oracle, users.rate_oracle_admin);
        accessControl.grantAccess(IOracle.setRateOracleData.selector, infra.oracle, users.rate_oracle_admin);

        accessControl.grantAccess(Lender.addAsset.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(Lender.removeAsset.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(Lender.pauseAsset.selector, infra.lender, users.lender_admin);

        accessControl.grantAccess(Lender.borrow.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(Lender.repay.selector, infra.lender, users.lender_admin);

        accessControl.grantAccess(Lender.liquidate.selector, infra.lender, users.lender_admin);
        accessControl.grantAccess(Lender.pauseAsset.selector, infra.lender, users.lender_admin);

        accessControl.grantAccess(Delegation.addAgent.selector, infra.delegation, users.delegation_admin);
        accessControl.grantAccess(Delegation.registerNetwork.selector, infra.delegation, users.delegation_admin);
    }
}
