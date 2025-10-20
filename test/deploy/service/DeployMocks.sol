// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { MockAaveDataProvider } from "../../mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../../mocks/MockChainlinkPriceFeed.sol";
import { TestEnvConfig } from "../interfaces/TestDeployConfig.sol";

import { ProxyUtils } from "../../../contracts/deploy/utils/ProxyUtils.sol";
import { IDelegation } from "../../../contracts/interfaces/IDelegation.sol";
import { Wrapper } from "../../../contracts/token/Wrapper.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { MockPermissionedERC20 } from "../../mocks/MockPermissionedERC20.sol";

import { MockNetwork } from "../../mocks/MockNetwork.sol";
import { MockNetworkMiddleware } from "../../mocks/MockNetworkMiddleware.sol";
import { OracleMocksConfig, TestUsersConfig } from "../interfaces/TestDeployConfig.sol";
import { Vm } from "forge-std/Vm.sol";

contract DeployMocks is ProxyUtils {
    function _deployOracleMocks(address[] memory assets) internal returns (OracleMocksConfig memory d) {
        d.assets = assets;
        d.aaveDataProviders = new address[](assets.length);
        d.chainlinkPriceFeeds = new address[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            d.aaveDataProviders[i] = address(new MockAaveDataProvider());
            d.chainlinkPriceFeeds[i] = address(new MockChainlinkPriceFeed(1e8));
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

    function _deployPermissionedMocks(address accessControl, address wrapperImplem, address usersInsuranceFund)
        internal
        returns (address[] memory permissionedMocks)
    {
        permissionedMocks = new address[](2);
        permissionedMocks[0] = address(new MockPermissionedERC20("USDP", "USDP", 18));
        permissionedMocks[1] = _proxy(wrapperImplem);
        Wrapper(permissionedMocks[1]).initialize(accessControl, usersInsuranceFund, permissionedMocks[0]);
    }

    function _deployDelegationNetworkMock() internal returns (address networkMiddleware, address network) {
        networkMiddleware = address(new MockNetworkMiddleware());
        network = address(new MockNetwork());
    }

    function _configureMockNetworkMiddleware(TestEnvConfig memory env, address networkMiddleware) internal {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

        vm.startPrank(env.users.delegation_admin);
        vm.expectRevert();
        IDelegation(env.infra.delegation).registerNetwork(address(0));
        IDelegation(env.infra.delegation).registerNetwork(networkMiddleware);

        address agent = env.testUsers.agents[0];
        IDelegation(env.infra.delegation).addAgent(agent, networkMiddleware, 0.5e27, 0.7e27);
    }

    function _setMockNetworkMiddlewareAgentCoverage(TestEnvConfig memory env, address agent, uint256 coverage)
        internal
    {
        MockNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).setMockCoverage(agent, coverage);
        MockNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).setMockSlashableCollateral(
            agent, coverage
        );
    }
}
