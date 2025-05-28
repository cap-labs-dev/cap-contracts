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

    function mockNetworkMiddleware_addMockAgentCoverage(address _agent, address _vault, uint256 _coverage)
        public
        asActor
    {
        mockNetworkMiddleware.addMockAgentCoverage(_agent, _vault, _coverage);
    }

    function mockNetworkMiddleware_distributeRewards(address _agent, address _token) public asActor {
        mockNetworkMiddleware.distributeRewards(_agent, _token);
    }

    function mockNetworkMiddleware_registerAgent(address _agent, address _vault) public asActor {
        mockNetworkMiddleware.registerAgent(_agent, _vault);
    }

    function mockNetworkMiddleware_registerVault(address _vault, address _stakerRewarder) public asActor {
        mockNetworkMiddleware.registerVault(_vault, _stakerRewarder);
    }

    function mockNetworkMiddleware_setFeeAllowed(uint256 _feeAllowed) public asActor {
        mockNetworkMiddleware.setFeeAllowed(_feeAllowed);
    }

    function mockNetworkMiddleware_setMockCollateralByVault(address _agent, address _vault, uint256 _collateral)
        public
        asActor
    {
        mockNetworkMiddleware.setMockCollateralByVault(_agent, _vault, _collateral);
    }

    function mockNetworkMiddleware_setMockCoverage(address _agent, uint256 _coverage) public asActor {
        mockNetworkMiddleware.setMockCoverage(_agent, _coverage);
    }

    function mockNetworkMiddleware_setMockSlashableCollateral(address _agent, uint256 _slashableCollateral)
        public
        asActor
    {
        mockNetworkMiddleware.setMockSlashableCollateral(_agent, _slashableCollateral);
    }

    function mockNetworkMiddleware_setMockSlashableCollateralByVault(
        address _agent,
        address _vault,
        uint256 _slashableCollateral
    ) public asActor {
        mockNetworkMiddleware.setMockSlashableCollateralByVault(_agent, _vault, _slashableCollateral);
    }

    function mockNetworkMiddleware_slash(address _agent, address _recipient, uint256 _slashShare, uint48)
        public
        asActor
    {
        mockNetworkMiddleware.slash(_agent, _recipient, _slashShare, 0);
    }
}
