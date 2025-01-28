// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessControl } from "../../access/AccessControl.sol";

import { Delegation } from "../../delegation/Delegation.sol";
import { Lender } from "../../lendingPool/Lender.sol";
import { InterestDebtToken } from "../../lendingPool/tokens/InterestDebtToken.sol";
import { PrincipalDebtToken } from "../../lendingPool/tokens/PrincipalDebtToken.sol";
import { RestakerDebtToken } from "../../lendingPool/tokens/RestakerDebtToken.sol";

import { Oracle } from "../../oracle/Oracle.sol";
import { CapToken } from "../../token/CapToken.sol";
import { StakedCap } from "../../token/StakedCap.sol";
import { ImplementationsConfig } from "../interfaces/DeployConfigs.sol";

contract DeployImplems {
    function _deployImplementations() internal returns (ImplementationsConfig memory d) {
        d.accessControl = address(new AccessControl());
        d.lender = address(new Lender());
        d.delegation = address(new Delegation());
        d.capToken = address(new CapToken());
        d.stakedCap = address(new StakedCap());
        d.oracle = address(new Oracle());
        d.principalDebtToken = address(new PrincipalDebtToken());
        d.interestDebtToken = address(new InterestDebtToken());
        d.restakerDebtToken = address(new RestakerDebtToken());
    }
}
