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

            _symbioticVaultSetCoveredAgentDelegation(symbioticWethVault, env.symbiotic.networkAdapter, 2e18);
            _symbioticVaultSetCoveredAgentDelegation(symbioticUsdtVault, env.symbiotic.networkAdapter, 1000e6);

            _timeTravel(symbioticUsdtVault.vaultEpochDuration + 1 days);

            vm.stopPrank();
        }
    }

    function test_slash_sends_funds_to_middleware() public {
        vm.startPrank(env.infra.delegation);

        address recipient = makeAddr("recipient");
        address agent = _getRandomAgent();

        // collateral in USDT (8 decimals)
        assertEq(middleware.coverage(agent), 6200e8);

        // slash 10% of agent collateral
        middleware.slash(agent, recipient, 0.1e18, uint48(block.timestamp) - 10);

        // all vaults have been slashed 10% and sent to the recipient
        assertApproxEqAbs(IERC20(usdt).balanceOf(recipient), 100e6, 1);
        assertApproxEqAbs(IERC20(weth).balanceOf(recipient), 2e17, 1);

        // vaults have hooks that update the limits on slash
        assertGt(middleware.coverage(agent), 5578e8);

        vm.stopPrank();
    }

    function test_slash_does_not_work_if_not_slashable() public {
        address agent = _getRandomAgent();

        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            // remove all delegations to our slashable agent
            _symbioticVaultSetCoveredAgentDelegation(symbioticUsdtVault, env.symbiotic.networkAdapter, 0);
            _symbioticVaultSetCoveredAgentDelegation(symbioticWethVault, env.symbiotic.networkAdapter, 0);

            vm.stopPrank();
        }

        _timeTravel(symbioticUsdtVault.vaultEpochDuration + 1);

        {
            vm.startPrank(env.infra.delegation);

            address recipient = makeAddr("recipient");
            assertEq(middleware.coverage(agent), 0);

            // we request a slash for a timestamp where there is a stake to be slashed
            middleware.slash(agent, recipient, 0.1e18, uint48(block.timestamp));

            // slash should not have worked
            assertEq(IERC20(usdt).balanceOf(recipient), 0);
            assertEq(IERC20(weth).balanceOf(recipient), 0);
            assertEq(middleware.coverage(agent), 0);
            vm.stopPrank();
        }
    }

    function test_can_slash_immediately_after_delegation() public {
        address agent = _getRandomAgent();

        // reset the initial stakes for this test
        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            _symbioticVaultSetCoveredAgentDelegation(symbioticUsdtVault, env.symbiotic.networkAdapter, 0);
            _symbioticVaultSetCoveredAgentDelegation(symbioticWethVault, env.symbiotic.networkAdapter, 0);
            _timeTravel(symbioticUsdtVault.vaultEpochDuration + 1 days);

            vm.stopPrank();
        }

        assertEq(middleware.coverage(agent), 0);

        // delegate to the agent
        {
            vm.startPrank(env.symbiotic.users.vault_admin);

            _symbioticVaultSetCoveredAgentDelegation(symbioticUsdtVault, env.symbiotic.networkAdapter, 1000e6);
            _symbioticVaultSetCoveredAgentDelegation(symbioticWethVault, env.symbiotic.networkAdapter, 2e18);

            vm.stopPrank();
        }

        // collateral is now active
        _timeTravel(3);
        assertEq(middleware.coverage(agent), 6200e8);

        // we should be able to slash immediately after delegation
        {
            vm.startPrank(env.infra.delegation);

            address recipient = makeAddr("recipient");

            middleware.slash(agent, recipient, 0.1e18, uint48(block.timestamp) - 1);

            // all vaults have been slashed 10% and sent to the recipient
            assertApproxEqAbs(IERC20(usdt).balanceOf(recipient), 100e6, 1);
            assertApproxEqAbs(IERC20(weth).balanceOf(recipient), 2e17, 1);

            vm.stopPrank();
        }
    }

    // ensure we can't slash if the vault epoch has ended
    // are funds active immediately after delegation?
    // can someone undelegate right before the epoch ends so that we don't have many blocks to react?
}
