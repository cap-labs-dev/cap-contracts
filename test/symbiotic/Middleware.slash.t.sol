// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { NetworkMiddleware } from "../../contracts/delegation/providers/symbiotic/NetworkMiddleware.sol";
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
        vm.startPrank(env.users.middleware_admin);

        address recipient = makeAddr("recipient");
        address agent = env.testUsers.agents[0];

        // collateral in USDT (8 decimals)
        assertEq(middleware.coverage(agent), 180_000e8);

        // slash 10% of agent collateral
        NetworkMiddleware.SymbioticSlashHint memory slashHint =
            NetworkMiddleware.SymbioticSlashHint({ slashTimestamp: uint48(block.timestamp - 1) });
        middleware.slash(agent, recipient, 0.1e18, abi.encode(slashHint));

        // all vaults have been slashed and sent to the recipient
        assertEq(IERC20(usdt).balanceOf(recipient), 9000e6);
        assertEq(IERC20(usdx).balanceOf(recipient), 9000e18);

        // collateral * price ($1) * 10% * collateral decimals / price decimals
        console.log("usdt balance of liquidator", IERC20(usdt).balanceOf(recipient));
        console.log("usdx balance of liquidator", IERC20(usdx).balanceOf(recipient));
        //  assertEq(IERC20(collateral).balanceOf(recipient), agentCollateral * 1e18 / 1e9);
        //  assertEq(IERC20(usdx).balanceOf(recipient), agentCollateral * 3200e8 / 1e9);

        vm.stopPrank();
    }

    function test_slash_does_not_work_if_not_slashable() public {
        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            // remove all delegations to our slashable agent
            address agent = env.testUsers.agents[0];
            _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, agent, 0);
            _symbioticVaultDelegateToAgent(symbioticUsdxVault, env.symbiotic.networkAdapter, agent, 0);

            vm.stopPrank();
        }

        _timeTravel(symbioticUsdtVault.vaultEpochDuration + 1);

        {
            vm.startPrank(env.users.middleware_admin);

            address recipient = makeAddr("recipient");
            address agent = env.testUsers.agents[0];

            // we request a slash for a timestamp where there is a stake to be slashed
            NetworkMiddleware.SymbioticSlashHint memory slashHint =
                NetworkMiddleware.SymbioticSlashHint({ slashTimestamp: uint48(block.timestamp - 10) });
            middleware.slash(agent, recipient, 1e17, abi.encode(slashHint));

            // slash should not have worked
            assertEq(IERC20(usdt).balanceOf(recipient), 0);
            assertEq(IERC20(usdx).balanceOf(recipient), 0);
            vm.stopPrank();
        }
    }
}
