// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { FeeAuction } from "../../contracts/lendingPool/FeeAuction.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeeAuctionBuyTest is TestDeployer {
    address realizer;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);
        _initSymbioticVaultsLiquidity(env);

        // initialize the realizer
        realizer = makeAddr("interest_realizer");
        _initTestUserMintCapToken(env.vault, realizer, 1000e18);

        // Have a random agent borrow to generate fees
        address borrower = env.testUsers.agents[1];
        vm.startPrank(borrower);
        lender.borrow(address(usdc), 1000e6, borrower);
        vm.stopPrank();

        _timeTravel(20 days);
    }

    function test_fee_auction_buy() public {
        // do a first buy to reset the auction timestamp
        {
            vm.startPrank(realizer);
            lender.realizeInterest(address(usdc), 1);
            feeAuction.buy(env.vault.assets, realizer, "");
            usdc.transfer(makeAddr("burn"), usdc.balanceOf(address(realizer)));
            vm.stopPrank();
        }

        // ensure the auction timestamp is reset
        assertEq(feeAuction.startTimestamp(), block.timestamp);

        // ensure the fee auction and realizer have nothing in it
        assertEq(usdc.balanceOf(address(feeAuction)), 0);
        assertEq(usdc.balanceOf(address(realizer)), 0);

        // ensure the auction price is the minimum start price
        assertEq(feeAuction.currentPrice(), feeAuction.minStartPrice());

        _timeTravel(1 hours);

        assertEq(feeAuction.currentPrice(), feeAuction.minStartPrice() * 2 / 3); // fee auction is 3h long

        // Save balances before buying
        uint256 usdcInterest = usdc.balanceOf(address(feeAuction));
        assertEq(usdcInterest, 0, "Fee auction should be empty before realizing interest");

        uint256 priceBeforeBuy = feeAuction.currentPrice();

        {
            vm.startPrank(realizer);

            // realize everything
            lender.realizeInterest(address(usdc), type(uint256).max);

            // realising interest should have created some fees
            assertGt(usdc.balanceOf(address(feeAuction)), 11e6, "Fee auction should have some fees");

            // Approve payment token (cUSD) for fee auction
            IERC20(env.vault.capToken).approve(address(feeAuction), type(uint256).max);
            feeAuction.buy(env.vault.assets, realizer, "");

            // ensure realizer balance increased by the expected amount
            assertGt(usdc.balanceOf(address(realizer)), 11e6, "Realizer USDC balance should have increased");

            vm.stopPrank();
        }

        // fee auction price doubles after buy
        assertEq(feeAuction.currentPrice(), priceBeforeBuy * 2);
    }
}
