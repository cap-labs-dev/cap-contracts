// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControl } from "../../access/AccessControl.sol";

import { Delegation } from "../../delegation/Delegation.sol";

import { FeeAuction } from "../../feeAuction/FeeAuction.sol";
import { Lender } from "../../lendingPool/Lender.sol";
import { DebtToken } from "../../lendingPool/tokens/DebtToken.sol";

import { Oracle } from "../../oracle/Oracle.sol";
import { CapToken } from "../../token/CapToken.sol";
import { StakedCap } from "../../token/StakedCap.sol";
import { ImplementationsConfig } from "../interfaces/DeployConfigs.sol";
import { InfraConfig } from "../interfaces/DeployConfigs.sol";
import { VaultConfig } from "../interfaces/DeployConfigs.sol";

contract UpgradeToAndCall {
    function _upgradeImplementations(ImplementationsConfig memory d, InfraConfig memory i, VaultConfig memory v)
        internal
    {
        AccessControl(i.accessControl).upgradeToAndCall(d.accessControl2, "");
        Lender(i.lender).upgradeToAndCall(d.lender2, "");
        Delegation(i.delegation).upgradeToAndCall(d.delegation2, "");
        CapToken(v.capToken).upgradeToAndCall(d.capToken2, "");
        StakedCap(v.stakedCapToken).upgradeToAndCall(d.stakedCap2, "");
        Oracle(i.oracle).upgradeToAndCall(d.oracle2, "");
        DebtToken(v.debtTokens[0]).upgradeToAndCall(d.debtToken2, "");
        FeeAuction(v.feeAuction).upgradeToAndCall(d.feeAuction2, "");
    }
}
