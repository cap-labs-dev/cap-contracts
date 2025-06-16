// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "contracts/feeReceiver/FeeReceiver.sol";

abstract contract FeeReceiverTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function feeReceiver_distribute() public asActor {
        feeReceiver.distribute();
    }

    function feeReceiver_setProtocolFeePercentage(uint256 _protocolFeePercentage) public asActor {
        feeReceiver.setProtocolFeePercentage(_protocolFeePercentage);
    }

    function feeReceiver_setProtocolFeeReceiver(address _protocolFeeReceiver) public asActor {
        feeReceiver.setProtocolFeeReceiver(_protocolFeeReceiver);
    }
}
