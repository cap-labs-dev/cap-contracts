// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SymbioticNetwork } from "../../contracts/delegation/providers/symbiotic/SymbioticNetwork.sol";
import { SymbioticNetworkMiddleware } from
    "../../contracts/delegation/providers/symbiotic/SymbioticNetworkMiddleware.sol";
import { TestDeployer } from "../../test/deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { console } from "forge-std/console.sol";

contract MiddlewareTest is TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initSymbioticVaultsLiquidity(env, 100);
    }

    function test_slash_sends_funds_to_middleware() public {
        vm.startPrank(env.infra.delegation);

        address recipient = makeAddr("recipient");
        address agent = _getRandomAgent();

        // collateral in USDT (8 decimals)
        assertEq(middleware.coverage(agent), 780000e8);

        // slash 10% of agent collateral
        middleware.slash(agent, recipient, 0.1e18, uint48(block.timestamp) - 10);

        // all vaults have been slashed 10% and sent to the recipient
        assertApproxEqAbs(IERC20(weth).balanceOf(recipient), 30e18, 1);

        // vaults have hooks that update the limits on slash
        assertApproxEqAbs(middleware.coverage(agent), 702000e8, 1);

        vm.stopPrank();
    }

    function test_slash_does_not_work_if_not_slashable() public {
        address agent = _getRandomAgent();

        _proportionallyWithdrawFromVault(env, symbioticWethVault.vault, 100, true);

        _timeTravel(symbioticWethVault.vaultEpochDuration * 2 + 1);

        {
            vm.startPrank(env.infra.delegation);

            address recipient = makeAddr("recipient");
            assertEq(middleware.coverage(agent), 0);

            // we request a slash for a timestamp where there is a stake to be slashed
            vm.expectRevert();
            middleware.slash(agent, recipient, 0.1e18, uint48(block.timestamp));

            // slash should not have worked
            assertEq(IERC20(weth).balanceOf(recipient), 0);
            assertEq(middleware.coverage(agent), 0);
            vm.stopPrank();
        }
    }

    function test_can_slash_immediately_after_delegation() public {
        address agent = _getRandomAgent();

        // collateral is now active
        _timeTravel(3);
        assertEq(middleware.coverage(agent), 780000e8);

        // we should be able to slash immediately after delegation
        {
            vm.startPrank(env.infra.delegation);

            address recipient = makeAddr("recipient");

            middleware.slash(agent, recipient, 0.1e18, uint48(block.timestamp) - 1);

            // all vaults have been slashed 10% and sent to the recipient
            assertApproxEqAbs(IERC20(weth).balanceOf(recipient), 30e18, 1);

            vm.stopPrank();
        }
    }

    // ensure we can't slash if the vault epoch has ended
    // are funds active immediately after delegation?
    // can someone undelegate right before the epoch ends so that we don't have many blocks to react?
}
