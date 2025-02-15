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

    uint256 alice_cUSD_balance;
    address alice = makeAddr("Alice");
    address bob = makeAddr("Bob");
    {   /// Alice and Bob get some CAP tokens

        /// Alice and Bob have 10000 USDT and USDC
        deal(address(usdt), alice, 10000e6);
        deal(address(usdc), bob, 10000e6);

        console.log("");
        console.log("--------------------------------");
        console.log("Alice and Bob Lifecycle Test");
        console.log("--------------------------------");
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

        alice_cUSD_balance = cUSD.balanceOf(alice);
        uint256 bob_cUSD_balance = cUSD.balanceOf(bob);

        console.log("Alice's cUSD balance", alice_cUSD_balance);
        console.log("Bob's cUSD balance", bob_cUSD_balance);
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
    }

    address mev_bot = makeAddr("Mev Bot");
    deal(address(usdt), mev_bot, 4000e6);
    address[] memory assets = new address[](1);
    assets[0] = address(usdt);

    {   /// An Operater comes to borrow USDT
        vm.startPrank(user_agent);

        /// Start with 1000 USDT in the operator's wallet
        deal(address(usdt), user_agent, 1000e6);
        lender.borrow(address(usdt), 1000e6, user_agent);
        assertEq(usdt.balanceOf(user_agent), 2000e6);

        console.log("Operator Borrowed 1000 USDT");
        console.log("Move time forward 10 days");
        console.log("");
        _timeTravel(10 days);

        /// Lets get the fee auction started
        vm.startPrank(mev_bot);

        usdt.approve(address(cUSD), 4000e6);
        cUSD.mint(address(usdt), 1000e6, 0, mev_bot, block.timestamp + 1 hours);

        lender.realizeInterest(address(usdt), 1);

        cUSD.approve(address(cUSDFeeAuction), 1000e18);
        uint256 startPrice = cUSDFeeAuction.currentPrice();
        console.log("Start price of fee auction", startPrice);
        cUSDFeeAuction.buy(assets, mev_bot, "");

        vm.stopPrank();
    }

    {   /// The operator repays the debt
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

        lender.repay(address(usdt), debt, user_agent);
        console.log("");

        (principalDebt, interestDebt, restakerDebt) = lender.debt(user_agent, address(usdt));
        assertEq(principalDebt, 0);
        assertEq(interestDebt, 0);
        assertEq(restakerDebt, 0);
        vm.stopPrank();
    }

    {   /// The fee auction is started and we send cUSD to scUSD
        vm.startPrank(mev_bot);

        usdt.approve(address(cUSD), 1000e6);
        cUSD.mint(address(usdt), 1000e6, 0, mev_bot, block.timestamp + 1 hours);

        cUSD.approve(address(cUSDFeeAuction), 1000e18);
        uint256 usdt_balance_before = usdt.balanceOf(address(cUSDFeeAuction));
        uint256 cUSD_balance_before = cUSD.balanceOf(address(scUSD));
        console.log("USDT balance of fee auction before buy", usdt_balance_before);
        console.log("cUSD balance of scUSD before buy", cUSD_balance_before);

        // Cheat a bit and get the price to match the assets in the auction
        vm.startPrank(env.users.fee_auction_admin);
        cUSDFeeAuction.setStartPrice(usdt_balance_before * 1e12);
        vm.stopPrank();

        vm.startPrank(mev_bot);

        uint256 startPrice = cUSDFeeAuction.startPrice();
        assertEq(startPrice, usdt_balance_before * 1e12);
       // console.log("Start price of fee auction", startPrice);
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

    {   /// Alice wants to withdraw her scUSD and should have more cUSD than before
        vm.startPrank(alice);
        _timeTravel(1 days);
        
        console.log("Locked profit of scUSD", scUSD.lockedProfit());
        uint256 alice_scUSD_balance = scUSD.balanceOf(alice);
        console.log("Alice's scUSD balance", alice_scUSD_balance);
        console.log("");

        vm.stopPrank();

        vm.startPrank(bob);

        /// Bob is being malicious and trying to withdraw Alice's cUSD
        vm.expectRevert();
        scUSD.withdraw(alice_scUSD_balance, bob, alice);

        vm.stopPrank();

        vm.startPrank(alice);
        scUSD.redeem(alice_scUSD_balance, alice, alice);
        console.log("Alice's cUSD balance after 11 day in scUSD and a borrow", cUSD.balanceOf(alice));
        console.log("");

        assertGt(cUSD.balanceOf(alice), alice_cUSD_balance);

        vm.stopPrank();
    }

    }
}