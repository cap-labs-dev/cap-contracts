// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "contracts/access/AccessControl.sol";

abstract contract AccessControlTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function accessControl_grantAccess(bytes4 _selector, address _contract, address _address) public asAdmin {
        accessControl.grantAccess(_selector, _contract, _address);
    }

    function accessControl_grantRole(bytes32 role, address account) public asAdmin {
        accessControl.grantRole(role, account);
    }

    function accessControl_renounceRole(bytes32 role, address callerConfirmation) public asAdmin {
        accessControl.renounceRole(role, callerConfirmation);
    }

    function accessControl_revokeAccess(bytes4 _selector, address _contract, address _address) public asAdmin {
        accessControl.revokeAccess(_selector, _contract, _address);
    }

    function accessControl_revokeRole(bytes32 role, address account) public asAdmin {
        accessControl.revokeRole(role, account);
    }
}
