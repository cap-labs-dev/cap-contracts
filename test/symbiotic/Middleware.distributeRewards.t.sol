// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

contract MiddlewareTest is TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initSymbioticVaultsLiquidity(env);
    }

    function test_distribute_rewards() public {
        vm.startPrank(env.infra.lender);

        // Send some rewards to the middleware
        MockERC20(symbioticUsdtVault.collateral).mint(address(middleware), 10e6);
        middleware.distributeRewards(symbioticUsdtVault.vault, address(symbioticUsdtVault.collateral));

        // Check that the rewards were distributed to the staker rewards contract
        assertEq(IERC20(usdt).balanceOf(symbioticUsdtNetworkRewards.stakerRewarder), 10e6);

        vm.stopPrank();
    }
}
