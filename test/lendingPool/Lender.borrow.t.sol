// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";

contract LenderBorrowTest is TestDeployer {
    address user_agent;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);
        user_agent = env.testUsers.agent;
    }

    function test_lender_borrow_and_repay() public {
        vm.startPrank(user_agent);

        uint256 backingBefore = usdc.balanceOf(address(cUSD));

        Lender(env.infra.lender).borrow(address(usdc), 1000e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 1000e6);

        //simulate yield
        usdc.mint(user_agent, 1000e6);

        // repay the debt
        usdc.approve(env.infra.lender, 1000e6 + 10e6);
        Lender(env.infra.lender).repay(address(usdc), 1000e6, user_agent);
        assertGe(usdc.balanceOf(address(cUSD)), backingBefore);
    }
}
