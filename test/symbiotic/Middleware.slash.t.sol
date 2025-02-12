// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Network } from "../../contracts/delegation/providers/symbiotic/Network.sol";
import { NetworkMiddleware } from "../../contracts/delegation/providers/symbiotic/NetworkMiddleware.sol";
import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { console } from "forge-std/console.sol";

contract MiddlewareTest is TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initSymbioticVaultsLiquidity(env);

        // reset the initial stakes for this test
        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            for (uint256 i = 0; i < env.testUsers.agents.length; i++) {
                address agent = env.testUsers.agents[i];
                _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, agent, 1000e6);
                _symbioticVaultDelegateToAgent(symbioticUsdxVault, env.symbiotic.networkAdapter, agent, 1000e18);
            }

            _timeTravel(symbioticUsdtVault.vaultEpochDuration + 1 days);

            vm.stopPrank();
        }
    }

    function test_slash_sends_funds_to_middleware() public {
        vm.startPrank(env.users.middleware_admin);

        address recipient = makeAddr("recipient");
        address agent = env.testUsers.agents[0];

        // collateral in USDT (8 decimals)
        assertEq(middleware.coverage(agent), 2000e8);

        // slash 10% of agent collateral
        middleware.slash(agent, recipient, 0.1e18, uint48(block.timestamp));

        // all vaults have been slashed 10% and sent to the recipient
        assertEq(IERC20(usdt).balanceOf(recipient), 100e6);
        assertEq(IERC20(usdx).balanceOf(recipient), 100e18);

        // vaults have hooks that update the limits on slash
        assertEq(middleware.coverage(agent), 1800e8);

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

            assertEq(middleware.coverage(agent), 0);

            // we request a slash for a timestamp where there is a stake to be slashed
            middleware.slash(agent, recipient, 0.1e18, uint48(block.timestamp));

            // slash should not have worked
            assertEq(IERC20(usdt).balanceOf(recipient), 0);
            assertEq(IERC20(usdx).balanceOf(recipient), 0);
            assertEq(middleware.coverage(agent), 0);
            vm.stopPrank();
        }
    }

    function test_expect_the_current_stake_to_be_exposed() public {
        address agent = env.testUsers.agents[0];

        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            // remove all delegations to our slashable agent
            _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, agent, 0);
            _symbioticVaultDelegateToAgent(symbioticUsdxVault, env.symbiotic.networkAdapter, agent, 0);

            _timeTravel(10);

            // remove all delegations to our slashable agent
            _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, agent, 1000e6);
            _symbioticVaultDelegateToAgent(symbioticUsdxVault, env.symbiotic.networkAdapter, agent, 1000e18);

            _timeTravel(10);

            vm.stopPrank();
        }

        // this is all within the same vault epoch
        //  |xxxxxxxxxx|----------|xxxxxxxxxx|
        //      2000   |    0     |    2000  |
        // -30        -20        -10         0

        assertEq(middleware.coverage(agent), 2000e8);
    }

    function test_current_agent_coverage_accounts_for_burner_router_changes() public {
        Network _network = Network(env.symbiotic.networkAdapter.network);
        NetworkMiddleware _middleware = NetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware);

        address agent = env.testUsers.agents[0];

        assertEq(middleware.coverage(agent), 2000e8);

        // vault admin changes the burner router receiver of the USDT vault
        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            address new_receiver = makeAddr("new_receiver");
            IBurnerRouter(symbioticUsdtVault.burnerRouter).setNetworkReceiver(address(_network), new_receiver);

            _timeTravel(10);

            vm.stopPrank();
        }

        // current coverage must reflect that change
        assertEq(middleware.coverage(agent), 1000e8);
    }

    function test_can_slash_immediately_after_delegation() public {
        address agent = env.testUsers.agents[0];

        // reset the initial stakes for this test
        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, agent, 0);
            _symbioticVaultDelegateToAgent(symbioticUsdxVault, env.symbiotic.networkAdapter, agent, 0);
            _timeTravel(symbioticUsdtVault.vaultEpochDuration + 1 days);

            vm.stopPrank();
        }

        assertEq(middleware.coverage(agent), 0);

        // delegate to the agent
        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, agent, 1000e6);
            _symbioticVaultDelegateToAgent(symbioticUsdxVault, env.symbiotic.networkAdapter, agent, 1000e18);

            vm.stopPrank();
        }

        // collateral is now active
        _timeTravel(1);
        assertEq(middleware.coverage(agent), 2000e8);

        // we should be able to slash immediately after delegation
        {
            vm.startPrank(env.users.middleware_admin);

            address recipient = makeAddr("recipient");

            middleware.slash(agent, recipient, 0.1e18, uint48(block.timestamp));

            // all vaults have been slashed 10% and sent to the recipient
            assertEq(IERC20(usdt).balanceOf(recipient), 100e6);
            assertEq(IERC20(usdx).balanceOf(recipient), 100e18);

            vm.stopPrank();
        }
    }

    // ensure we can't slash if the vault epoch has ended
    // are funds active immediately after delegation?
    // can someone undelegate right before the epoch ends so that we don't have many blocks to react?
}
