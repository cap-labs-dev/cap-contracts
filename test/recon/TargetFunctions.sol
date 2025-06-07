// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

// Targets
// NOTE: Always import and apply them in alphabetical order, so much easier to debug!
import { AccessControlTargets } from "./targets/AccessControlTargets.sol";
import { AdminTargets } from "./targets/AdminTargets.sol";
import { CapTokenTargets } from "./targets/CapTokenTargets.sol";
import { DebtTokenTargets } from "./targets/DebtTokenTargets.sol";
import { DelegationTargets } from "./targets/DelegationTargets.sol";
import { DoomsdayTargets } from "./targets/DoomsdayTargets.sol";
import { FeeAuctionTargets } from "./targets/FeeAuctionTargets.sol";
import { LenderTargets } from "./targets/LenderTargets.sol";
import { ManagersTargets } from "./targets/ManagersTargets.sol";
import { MockAaveDataProviderTargets } from "./targets/MockAaveDataProviderTargets.sol";
import { MockChainlinkPriceFeedTargets } from "./targets/MockChainlinkPriceFeedTargets.sol";
import { MockERC4626TesterTargets } from "./targets/MockERC4626TesterTargets.sol";
import { MockNetworkMiddlewareTargets } from "./targets/MockNetworkMiddlewareTargets.sol";
import { OracleTargets } from "./targets/OracleTargets.sol";
import { StakedCapTargets } from "./targets/StakedCapTargets.sol";

import "contracts/lendingPool/tokens/DebtToken.sol";
import "test/mocks/MockAaveDataProvider.sol";
import "test/mocks/MockChainlinkPriceFeed.sol";

abstract contract TargetFunctions is
    AccessControlTargets,
    AdminTargets,
    CapTokenTargets,
    DebtTokenTargets,
    DelegationTargets,
    DoomsdayTargets,
    FeeAuctionTargets,
    LenderTargets,
    ManagersTargets,
    MockAaveDataProviderTargets,
    MockChainlinkPriceFeedTargets,
    MockNetworkMiddlewareTargets,
    OracleTargets,
    StakedCapTargets,
    MockERC4626TesterTargets
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    function switchChainlinkOracle(uint256 entropy) public {
        address target = env.usdOracleMocks.chainlinkPriceFeeds[entropy % env.usdOracleMocks.chainlinkPriceFeeds.length];
        mockChainlinkPriceFeed = MockChainlinkPriceFeed(target);
    }

    function switchAaveOracle(uint256 entropy) public {
        address target = env.usdOracleMocks.aaveDataProviders[entropy % env.usdOracleMocks.aaveDataProviders.length];
        mockAaveDataProvider = MockAaveDataProvider(target);
    }

    function switchDebtToken(uint256 entropy) public {
        address target = env.usdVault.debtTokens[entropy % env.usdVault.debtTokens.length];
        debtToken = DebtToken(target);
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}
