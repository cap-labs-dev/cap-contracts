// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { FeeReceiver } from "../../contracts/feeReceiver/FeeReceiver.sol";
import { IFeeReceiver } from "../../contracts/interfaces/IFeeReceiver.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeesDistributeTest is TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
    }

    function test_distribute_no_fees() public {
        deal(address(usdVault.capToken), usdVault.feeReceiver, 100e18);

        uint256 stakedCapBalanceBefore = IERC20(usdVault.capToken).balanceOf(address(usdVault.stakedCapToken));

        FeeReceiver(usdVault.feeReceiver).distribute();

        assertEq(IERC20(usdVault.capToken).balanceOf(address(usdVault.feeReceiver)), 0);
        assertEq(IERC20(usdVault.capToken).balanceOf(address(usdVault.stakedCapToken)) - stakedCapBalanceBefore, 100e18);
    }

    function test_distribute_with_fees() public {
        vm.startPrank(env.users.vault_config_admin);

        address treasury = makeAddr("treasury");
        FeeReceiver(usdVault.feeReceiver).setProtocolFeeReceiver(treasury);

        // 10% of fees go to treasury
        FeeReceiver(usdVault.feeReceiver).setProtocolFeePercentage(0.1e18);

        deal(address(usdVault.capToken), usdVault.feeReceiver, 100e18);

        uint256 stakedCapBalanceBefore = IERC20(usdVault.capToken).balanceOf(address(usdVault.stakedCapToken));

        FeeReceiver(usdVault.feeReceiver).distribute();

        assertEq(IERC20(usdVault.capToken).balanceOf(address(usdVault.feeReceiver)), 0);
        assertEq(IERC20(usdVault.capToken).balanceOf(address(usdVault.stakedCapToken)) - stakedCapBalanceBefore, 90e18);
        assertEq(IERC20(usdVault.capToken).balanceOf(treasury), 10e18);
    }

    function test_reverts() public {
        vm.startPrank(env.users.vault_config_admin);

        address treasury = makeAddr("treasury");
        vm.expectRevert(IFeeReceiver.NoProtocolFeeReceiverSet.selector);
        FeeReceiver(usdVault.feeReceiver).setProtocolFeePercentage(0.1e18);

        vm.expectRevert(IFeeReceiver.InvalidProtocolFeePercentage.selector);
        FeeReceiver(usdVault.feeReceiver).setProtocolFeePercentage(1e18 + 1);

        vm.stopPrank();

        vm.startPrank(treasury);
        vm.expectRevert();
        FeeReceiver(usdVault.feeReceiver).setProtocolFeePercentage(0.1e18);
        vm.expectRevert();
        FeeReceiver(usdVault.feeReceiver).setProtocolFeeReceiver(treasury);
        vm.stopPrank();
    }
}
