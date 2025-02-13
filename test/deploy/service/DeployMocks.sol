// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { MockAaveDataProvider } from "../../mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../../mocks/MockChainlinkPriceFeed.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { OracleMocksConfig, TestUsersConfig } from "../interfaces/TestDeployConfig.sol";

contract DeployMocks {
    function _deployOracleMocks(address[] memory assets) internal returns (OracleMocksConfig memory d) {
        d.assets = assets;
        d.aaveDataProviders = new address[](assets.length);
        d.chainlinkPriceFeeds = new address[](assets.length + 1);

        for (uint256 i = 0; i < assets.length; i++) {
            d.aaveDataProviders[i] = address(new MockAaveDataProvider());
            d.chainlinkPriceFeeds[i] = address(new MockChainlinkPriceFeed());
        }

        d.chainlinkPriceFeeds[assets.length] = address(new MockChainlinkPriceFeed()); // weth
    }

    function _initOracleMocks(OracleMocksConfig memory d) internal {
        for (uint256 i = 0; i < d.assets.length; i++) {
            MockChainlinkPriceFeed(d.chainlinkPriceFeeds[i]).setDecimals(8);
            MockChainlinkPriceFeed(d.chainlinkPriceFeeds[i]).setLatestAnswer(1e8); // $1.00 with 8 decimals
            MockAaveDataProvider(d.aaveDataProviders[i]).setVariableBorrowRate(1e26); // 10% APY, 1e27 = 100%
        }

        MockChainlinkPriceFeed(d.chainlinkPriceFeeds[d.assets.length]).setDecimals(8);
        MockChainlinkPriceFeed(d.chainlinkPriceFeeds[d.assets.length]).setLatestAnswer(2600e8); // $2600 with 8 decimals
    }

    function _deployUSDMocks() internal returns (address[] memory usdMocks) {
        usdMocks = new address[](3);
        usdMocks[0] = address(new MockERC20("USDT", "USDT", 6));
        usdMocks[1] = address(new MockERC20("USDC", "USDC", 6));
        usdMocks[2] = address(new MockERC20("USDx", "USDx", 18));
    }

    function _deployEthMock() internal returns (address ethMock) {
        ethMock = address(new MockERC20("WETH", "WETH", 18));
    }
}
