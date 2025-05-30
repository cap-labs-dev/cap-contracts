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
    function mockNetworkMiddleware_setMockSlashableCollateral_clamped(bool liquidatable) public {
        // This function is used to prepare the state for liquidation tests
        // It sets up the necessary conditions for a liquidation to occur
        if (liquidatable) {
            mockNetworkMiddleware_setMockSlashableCollateral(1e8);
        } else {
            mockNetworkMiddleware_setMockSlashableCollateral(1e20);
        }
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function mockNetworkMiddleware_addMockAgentCoverage(uint256 _coverage) public asActor {
        mockNetworkMiddleware.addMockAgentCoverage(agent, address(capToken), _coverage);
    }

    function mockNetworkMiddleware_distributeRewards(address _token) public asActor {
        mockNetworkMiddleware.distributeRewards(agent, _token);
    }

    function mockNetworkMiddleware_registerAgent() public asActor {
        mockNetworkMiddleware.registerAgent(agent, address(capToken));
    }

    function mockNetworkMiddleware_registerVault(address _stakerRewarder) public asActor {
        mockNetworkMiddleware.registerVault(address(capToken), _stakerRewarder);
    }

    function mockNetworkMiddleware_setFeeAllowed(uint256 _feeAllowed) public asActor {
        mockNetworkMiddleware.setFeeAllowed(_feeAllowed);
    }

    function mockNetworkMiddleware_setMockCollateralByVault(address _vault, uint256 _collateral) public asActor {
        mockNetworkMiddleware.setMockCollateralByVault(agent, address(capToken), _collateral);
    }

    function mockNetworkMiddleware_setMockCoverage(uint256 _coverage) public asActor {
        mockNetworkMiddleware.setMockCoverage(agent, _coverage);
    }

    function mockNetworkMiddleware_setMockSlashableCollateral(uint256 _slashableCollateral) public asActor {
        mockNetworkMiddleware.setMockSlashableCollateral(agent, _slashableCollateral);
    }

    function mockNetworkMiddleware_setMockSlashableCollateralByVault(uint256 _slashableCollateral) public asActor {
        mockNetworkMiddleware.setMockSlashableCollateralByVault(agent, address(capToken), _slashableCollateral);
    }

    function mockNetworkMiddleware_slash(address _recipient, uint256 _slashShare, uint48) public asActor {
        mockNetworkMiddleware.slash(agent, _recipient, _slashShare, 0);
    }
}
