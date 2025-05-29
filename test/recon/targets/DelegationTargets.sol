// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "contracts/delegation/Delegation.sol";

abstract contract DelegationTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function delegation_addAgent(address _agent, address _network, uint256 _ltv, uint256 _liquidationThreshold)
        public
        asActor
    {
        delegation.addAgent(_agent, _network, _ltv, _liquidationThreshold);
    }

    function delegation_distributeRewards(address _agent, address _asset) public asActor {
        delegation.distributeRewards(_agent, _asset);
    }

    function delegation_modifyAgent(address _agent, uint256 _ltv, uint256 _liquidationThreshold) public asActor {
        delegation.modifyAgent(_agent, _ltv, _liquidationThreshold);
    }

    function delegation_registerNetwork(address _network) public asActor {
        delegation.registerNetwork(_network);
    }

    function delegation_setLastBorrow(address _agent) public asActor {
        delegation.setLastBorrow(_agent);
    }

    function delegation_setLtvBuffer(uint256 _ltvBuffer) public asActor {
        delegation.setLtvBuffer(_ltvBuffer);
    }

    function delegation_slash(address _agent, address _liquidator, uint256 _amount) public asActor {
        delegation.slash(_agent, _liquidator, _amount);
    }
}
