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
        d.chainlinkPriceFeeds = new address[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            d.aaveDataProviders[i] = address(new MockAaveDataProvider());
            d.chainlinkPriceFeeds[i] = address(new MockChainlinkPriceFeed());
        }
    }

    function _initOracleMocks(OracleMocksConfig memory d, int256 latestAnswer, uint256 variableBorrowRate) internal {
        for (uint256 i = 0; i < d.assets.length; i++) {
            MockChainlinkPriceFeed(d.chainlinkPriceFeeds[i]).setDecimals(8);
            MockChainlinkPriceFeed(d.chainlinkPriceFeeds[i]).setLatestAnswer(latestAnswer);
            MockAaveDataProvider(d.aaveDataProviders[i]).setVariableBorrowRate(variableBorrowRate);
        }
    }

    function _deployUSDMocks() internal returns (address[] memory usdMocks) {
        usdMocks = new address[](3);
        usdMocks[0] = address(new MockERC20("USDT", "USDT", 6));
        usdMocks[1] = address(new MockERC20("USDC", "USDC", 6));
        usdMocks[2] = address(new MockERC20("USDx", "USDx", 18));
    }

    function _deployEthMocks() internal returns (address[] memory ethMocks) {
        ethMocks = new address[](1);
        ethMocks[0] = address(new MockERC20("WETH", "WETH", 18));
    }
}
