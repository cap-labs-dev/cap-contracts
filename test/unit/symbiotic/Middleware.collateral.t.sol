// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SymbioticNetwork } from "../../../contracts/delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkMiddleware } from
    "../../../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";
import { TestDeployer } from "../../deploy/TestDeployer.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { console } from "forge-std/console.sol";

contract MiddlewareTest is TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initSymbioticVaultsLiquidity(env, 100);

        // reset the initial stakes for this test
        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            _timeTravel(symbioticWethVault.vaultEpochDuration + 1 days);

            vm.stopPrank();
        }
    }
    /*
    function test_expect_the_current_stake_to_be_exposed() public {
        address agent = _getRandomAgent();

        {

            // remove all delegations to our slashable agent
            _symbioticVaultDelegateToAgent(symbioticWethVault, env.symbiotic.networkAdapter, agent, 0);
            // _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, agent, 0);

            _timeTravel(10);

            // remove all delegations to our slashable agent
            _symbioticVaultDelegateToAgent(symbioticWethVault, env.symbiotic.networkAdapter, agent, 2e18);
            // _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, agent, 1000e6);

            _timeTravel(10);

        }

        // this is all within the same vault epoch
        //  |xxxxxxxxxx|----------|xxxxxxxxxx|
        //      2000   |    0     |    2000  |
        // -30        -20        -10         0

        assertEq(middleware.coverage(agent), 5200e8);
    }*/
}
