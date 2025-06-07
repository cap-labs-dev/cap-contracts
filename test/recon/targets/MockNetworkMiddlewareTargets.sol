// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "test/mocks/MockNetworkMiddleware.sol";

abstract contract MockNetworkMiddlewareTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    function mockNetworkMiddleware_setMockCollateralByVault(address _vault, uint256 _collateral) public asActor {
        mockNetworkMiddleware.setMockCollateralByVault(agent, _vault, _collateral);
    }
}
