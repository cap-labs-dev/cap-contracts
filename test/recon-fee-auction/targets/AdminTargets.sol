// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

// Your deps
import "contracts/feeAuction/FeeAuction.sol";

abstract contract AdminTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    function feeAuction_setDuration(uint256 _duration) public asAdmin {
        feeAuction.setDuration(_duration);
    }

    function feeAuction_setMinStartPrice(uint256 _minStartPrice) public asAdmin {
        feeAuction.setMinStartPrice(_minStartPrice);
    }

    function feeAuction_setStartPrice(uint256 _startPrice) public asAdmin {
        feeAuction.setStartPrice(_startPrice);
    }
}
