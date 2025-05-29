// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "test/mocks/MockChainlinkPriceFeed.sol";

abstract contract MockChainlinkPriceFeedTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    // function mockChainlinkPriceFeed_setDecimals(uint8 decimals_) public asActor {
    //     mockChainlinkPriceFeed.setDecimals(decimals_);
    // }

    function mockChainlinkPriceFeed_setLatestAnswer(int256 answer) public asActor {
        mockChainlinkPriceFeed.setLatestAnswer(answer);
    }

    function mockChainlinkPriceFeed_setMockPriceStaleness(uint256 staleness) public asActor {
        mockChainlinkPriceFeed.setMockPriceStaleness(staleness);
    }
}
