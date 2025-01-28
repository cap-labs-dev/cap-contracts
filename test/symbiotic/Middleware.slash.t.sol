// SPDX-License-Identifier: MIT
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

    function test_slash_sends_funds_to_middleware() public {
        // it is slashable
        {
            vm.startPrank(env.users.middleware_admin);

            address recipient = makeAddr("recipient");
            address agent = env.testUsers.agents[0];

            // collateral in USDT (8 decimals)
            uint256 agentCollateral = middleware.coverage(agent);
            console.log("agentCollateral", agentCollateral);

            // slash 10% of agent collateral
            middleware.slash(agent, recipient, 1e17);

            // collateral * price ($1) * 10% * collateral decimals / price decimals
            console.log("usdt balance of liquidator", IERC20(usdt).balanceOf(recipient));
            console.log("usdx balance of liquidator", IERC20(usdx).balanceOf(recipient));
            //  assertEq(IERC20(collateral).balanceOf(recipient), agentCollateral * 1e18 / 1e9);
            //  assertEq(IERC20(usdx).balanceOf(recipient), agentCollateral * 3200e8 / 1e9);

            vm.stopPrank();
        }

        /// Test whether or not we can slash after the slashable period??
        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            // remove delegations to our slashable agent
            address agent = env.testUsers.agents[0];
            _symbioticVaultOptInToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, agent, 0);

            vm.stopPrank();
        }

        // move ahead slashduration plus 1 into the future
        _timeTravel(symbioticUsdtVault.vaultEpochDuration + 1);

        {
            vm.startPrank(env.users.middleware_admin);

            address recipient = makeAddr("recipient");
            address agent = env.testUsers.agents[0];

            vm.expectRevert();
            // slash 10% of agent collateral
            middleware.slash(agent, recipient, 1e17);

            vm.stopPrank();
        }
    }
}
