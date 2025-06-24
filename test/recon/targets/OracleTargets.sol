// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "contracts/oracle/Oracle.sol";

abstract contract OracleTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function oracle_setBenchmarkRate(address _asset, uint256 _rate) public asActor {
        _rate %= (RAY + 1); // upper bound of 100% interest rates
        oracle.setBenchmarkRate(_asset, _rate);
    }

    function oracle_setRestakerRate(address _agent, uint256 _rate) public asActor {
        oracle.setRestakerRate(_agent, _rate);
    }

    function oracle_setStaleness(address _asset, uint256 _staleness) public asActor {
        oracle.setStaleness(_asset, _staleness);
    }
}
