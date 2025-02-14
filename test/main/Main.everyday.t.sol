// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { console } from "forge-std/console.sol";

contract MainEverydayTest is TestDeployer {
    address user_agent;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
        _initSymbioticVaultsLiquidity(env);

        user_agent = _getRandomAgent();

        vm.startPrank(env.symbiotic.users.vault_admin);
        _symbioticVaultDelegateToAgent(symbioticWethVault, env.symbiotic.networkAdapter, user_agent, 2e18);
        _symbioticVaultDelegateToAgent(symbioticUsdtVault, env.symbiotic.networkAdapter, user_agent, 1000e6);
        vm.stopPrank();

        _setAssetOraclePrice(address(usdc), 0.99985e8);
    }

    function test_everyday_functionality() public {

        address alice = makeAddr("Alice");
        address bob = makeAddr("Bob");

        /// Alice and Bob have 10000 USDT and USDC
        deal(address(usdt), alice, 10000e6);
        deal(address(usdc), bob, 10000e6);

        console.log("Alice and Bob Lifecycle Test");
        console.log("");

        console.log("Price of USDT in 8 decimals", uint256(1e8));
        console.log("Price of USDC in 8 decimals", uint256(0.99985e8));
        console.log("");

        console.log("Alice's USDT balance", usdt.balanceOf(alice));
        console.log("Bob's USDC balance", usdc.balanceOf(bob));
        console.log("");

        vm.startPrank(alice);

        usdt.approve(address(cUSD), 10000e6);
        cUSD.mint(address(usdt), 2000e6, 9998e6, alice, block.timestamp + 1 hours);

        /// Alice is deposting 2000 USDT but since USDC is off peg she gets more than 2000 cUSD
        assertGt(cUSD.balanceOf(alice), 2000e18);
        vm.stopPrank();

        vm.startPrank(bob);

        usdc.approve(address(cUSD), 10000e6);
        cUSD.mint(address(usdc), 2000e6, 1998e6, bob, block.timestamp + 1 hours);

        assertLt(cUSD.balanceOf(bob), 2000e18);

        console.log("Alice's cUSD balance", cUSD.balanceOf(alice));
        console.log("Bob's cUSD balance", cUSD.balanceOf(bob));
        console.log("");

        console.log("Alice's USDT balance", usdt.balanceOf(alice));
        console.log("Bob's USDC balance", usdc.balanceOf(bob));
        console.log("");
        
        vm.stopPrank();

        vm.startPrank(alice);

        uint256 alice_cUSD_balance = cUSD.balanceOf(alice);
        cUSD.approve(address(scUSD), alice_cUSD_balance);
        scUSD.deposit(alice_cUSD_balance, alice);

        console.log("Alice's scUSD balance", scUSD.balanceOf(alice));
        assertEq(scUSD.balanceOf(alice), alice_cUSD_balance);
        console.log("");

        vm.stopPrank();

        vm.startPrank(user_agent);

        lender.borrow(address(usdt), 1000e6, user_agent);
        assertEq(usdt.balanceOf(user_agent), 1000e6);

        console.log("Operator Borrowed 1000 USDT");
        console.log("Move time forward 10 days");
        console.log("");
        _timeTravel(10 days);

        console.log("Operator Repays 1000 USDT plus interest");
        (uint256 principalDebt, uint256 interestDebt, uint256 restakerDebt) = lender.debt(user_agent, address(usdt));
        console.log("Principal Debt", principalDebt);
        console.log("Interest Debt", interestDebt);
        console.log("Restaker Debt", restakerDebt);
        uint256 debt = principalDebt + interestDebt + restakerDebt;
        console.log("");

        deal(address(usdt), user_agent,  1000e6);
        usdt.approve(address(lender), debt);
        lender.repay(address(usdt), debt, user_agent);

        console.log("Operator Repays", debt);

        (principalDebt, interestDebt, restakerDebt) = lender.debt(user_agent, address(usdt));
        assertEq(principalDebt, 0);
        assertEq(interestDebt, 0);
        assertEq(restakerDebt, 0);
        vm.stopPrank();
    }
}