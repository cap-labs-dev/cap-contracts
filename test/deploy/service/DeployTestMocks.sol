// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { MockAaveDataProvider } from "../../mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../../mocks/MockChainlinkPriceFeed.sol";
import { MockDelegation } from "../../mocks/MockDelegation.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { DelegationMockConfig, OracleMocksConfig, TestUsersConfig } from "../interfaces/TestDeployConfig.sol";

contract DeployMocks {
    function _deployDelegationMock(address agent) internal returns (DelegationMockConfig memory d) {
        d.delegators = new address[](3);
        for (uint256 i = 0; i < d.delegators.length; i++) {
            d.delegators[i] = address(new MockDelegation());
            MockDelegation(d.delegators[i]).setCoverage(agent, 100000e18);
            MockDelegation(d.delegators[i]).setLtv(agent, 1e18);
            MockDelegation(d.delegators[i]).setLiquidationThreshold(agent, 1e18);
        }
    }

    function _deployOracleMocks(address[] memory assets) internal returns (OracleMocksConfig memory d) {
        d.assets = assets;
        d.aaveDataProviders = new address[](assets.length);
        d.chainlinkPriceFeeds = new address[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            d.aaveDataProviders[i] = address(new MockAaveDataProvider());
            d.chainlinkPriceFeeds[i] = address(new MockChainlinkPriceFeed());
        }
    }

    function _initOracleMocks(OracleMocksConfig memory d) internal {
        for (uint256 i = 0; i < d.assets.length; i++) {
            MockChainlinkPriceFeed(d.chainlinkPriceFeeds[i]).setDecimals(8);
            MockChainlinkPriceFeed(d.chainlinkPriceFeeds[i]).setLatestAnswer(1e8); // $1.00 with 8 decimals
            MockAaveDataProvider(d.aaveDataProviders[i]).setVariableBorrowRate(1e17); // 10% APY, 1e18 = 100%
        }
    }

    function _deployUSDMocks() internal returns (address[] memory usdMocks) {
        usdMocks = new address[](3);
        usdMocks[0] = address(new MockERC20("USDT", "USDT", 6));
        usdMocks[1] = address(new MockERC20("USDC", "USDC", 6));
        usdMocks[2] = address(new MockERC20("USDx", "USDx", 18));
    }
}
