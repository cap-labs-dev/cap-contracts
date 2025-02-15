// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IRestakerDebtToken } from "../../contracts/interfaces/IRestakerDebtToken.sol";
import { IInterestDebtToken } from "../../contracts/interfaces/IInterestDebtToken.sol";
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

        /// Start with 1000 USDT in the operator's wallet
        deal(address(usdt), user_agent, 1000e6);
        lender.borrow(address(usdt), 1000e6, user_agent);
        assertEq(usdt.balanceOf(user_agent), 2000e6);

        console.log("Operator Borrowed 1000 USDT");
        console.log("Move time forward 10 days");
        console.log("");
        _timeTravel(1 days);

        address mev_bot = makeAddr("Mev Bot");
        deal(address(usdt), mev_bot, 1000e6);
        vm.startPrank(mev_bot);

     //   usdt.approve(address(cUSD), 1000e6);
     //   cUSD.mint(address(usdt), 1000e6, 0, mev_bot, block.timestamp + 1 hours);

     //   lender.realizeInterest(address(usdt), 1);

   //     cUSD.approve(address(cUSDFeeAuction), 1000e18);
        address[] memory assets = new address[](1);
        assets[0] = address(usdt);
   //     cUSDFeeAuction.buy(assets, mev_bot, "");
    {    uint256 block_timestamp = block.timestamp;
        console.log("Block timestamp", block_timestamp);
        (uint256 interest_per_second, uint256 last_update) = IRestakerDebtToken(env.usdVault.interestDebtTokens[0]).agent(user_agent);
        uint256 current_index = IInterestDebtToken(env.usdVault.interestDebtTokens[0]).currentIndex();
        console.log("Current Index", current_index);
        console.log("Interest Per Second", interest_per_second);
        console.log("Last Update", last_update);}
        _timeTravel(10 days);

        vm.stopPrank();

        vm.startPrank(user_agent);
        (uint256 principalDebt, uint256 interestDebt, uint256 restakerDebt) = lender.debt(user_agent, address(usdt));
        console.log("Debt in USDT 6 Decimals");
        console.log("Principal Debt", principalDebt);
        console.log("Interest Debt", interestDebt);
        console.log("Restaker Debt", restakerDebt);
        uint256 debt = principalDebt + interestDebt + restakerDebt;
        console.log("");

        usdt.approve(address(lender), debt);
        console.log("Operator Repays", debt);

        console.log("Market Rate", IOracle(env.infra.oracle).marketRate(address(usdt)));
        console.log("Benchmark Rate", IOracle(env.infra.oracle).benchmarkRate(address(usdt)));
        console.log("Utilization Rate", IOracle(env.infra.oracle).utilizationRate(address(usdt)));
        console.log("Restaker Rate", IOracle(env.infra.oracle).restakerRate(user_agent));
        console.log("Total Interest Per Second", IRestakerDebtToken(env.usdVault.restakerDebtTokens[0]).totalInterestPerSecond());

        lender.repay(address(usdt), debt, user_agent);
        console.log("");

        (principalDebt, interestDebt, restakerDebt) = lender.debt(user_agent, address(usdt));
        assertEq(principalDebt, 0);
        assertEq(interestDebt, 0);
        assertEq(restakerDebt, 0);
        vm.stopPrank();
{
        vm.startPrank(mev_bot);

        usdt.approve(address(cUSD), 1000e6);
        cUSD.mint(address(usdt), 1000e6, 0, mev_bot, block.timestamp + 1 hours);

        cUSD.approve(address(cUSDFeeAuction), 1000e18);
        uint256 usdt_balance_before = usdt.balanceOf(address(cUSDFeeAuction));
        uint256 cUSD_balance_before = cUSD.balanceOf(address(scUSD));
        console.log("USDT balance of fee auction before buy", usdt_balance_before);
        console.log("cUSD balance of scUSD before buy", cUSD_balance_before);
        uint256 startPrice = cUSDFeeAuction.startPrice();
        console.log("Start price of fee auction", startPrice);
        cUSDFeeAuction.buy(assets, mev_bot, "");
        uint256 usdt_balance_after = usdt.balanceOf(address(cUSDFeeAuction));
        uint256 cUSD_balance_after = cUSD.balanceOf(address(scUSD));
        console.log("USDT balance of fee auction after buy", usdt_balance_after);
        console.log("cUSD balance of scUSD after buy", cUSD_balance_after);

        scUSD.notify();

        console.log("Mev Bot's cUSD balance", cUSD.balanceOf(mev_bot));
        console.log("");

        vm.stopPrank();
}
        vm.startPrank(alice);
        _timeTravel(1 days);
        
        uint256 alice_scUSD_balance = scUSD.balanceOf(alice);
        console.log("Alice's scUSD balance", alice_scUSD_balance);
        console.log("");

        vm.stopPrank();

        vm.startPrank(bob);

        vm.expectRevert();
        scUSD.withdraw(alice_scUSD_balance, bob, alice);

        vm.stopPrank();

        vm.startPrank(alice);
        scUSD.withdraw(alice_scUSD_balance, alice, alice);
        console.log("Alice's cUSD balance after 11 day in scUSD and a borrow", cUSD.balanceOf(alice));
        console.log("");

        vm.stopPrank();

    }
}