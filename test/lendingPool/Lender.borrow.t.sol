// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { Vault } from "../../contracts/vault/Vault.sol";

import { InterestDebtToken } from "../../contracts/lendingPool/tokens/InterestDebtToken.sol";
import { PrincipalDebtToken } from "../../contracts/lendingPool/tokens/PrincipalDebtToken.sol";
import { RestakerDebtToken } from "../../contracts/lendingPool/tokens/RestakerDebtToken.sol";

import { ValidationLogic } from "../../contracts/lendingPool/libraries/ValidationLogic.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { console } from "forge-std/console.sol";

contract LenderBorrowTest is TestDeployer {
    address user_agent;

    PrincipalDebtToken principalDebtToken;
    RestakerDebtToken restakerDebtToken;
    InterestDebtToken interestDebtToken;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
        _initSymbioticVaultsLiquidity(env);

        user_agent = _getRandomAgent();

        vm.startPrank(env.symbiotic.users.vault_admin);
        _symbioticVaultDelegateToAgent(symbioticWethVault, env.symbiotic.networkAdapter, user_agent, 2e18);

        uint256 assetIndex = _getAssetIndex(usdVault, address(usdc));
        principalDebtToken = PrincipalDebtToken(usdVault.principalDebtTokens[assetIndex]);
        restakerDebtToken = RestakerDebtToken(usdVault.restakerDebtTokens[assetIndex]);
        interestDebtToken = InterestDebtToken(usdVault.interestDebtTokens[assetIndex]);
    }

    function test_lender_borrow_and_repay() public {
        vm.startPrank(user_agent);

        uint256 backingBefore = usdc.balanceOf(address(cUSD));

        vm.expectRevert(ValidationLogic.MinBorrowAmount.selector);
        lender.borrow(address(usdc), 99e6, user_agent);

        lender.borrow(address(usdc), 1000e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 1000e6);

        // simulate yield
        usdc.mint(user_agent, 1000e6);

        // repay the debt
        usdc.approve(env.infra.lender, 1000e6 + 10e6);
        lender.repay(address(usdc), 1000e6, user_agent);
        assertGe(usdc.balanceOf(address(cUSD)), backingBefore);

        assertDebtEq(0, 0, 0);
    }

    function test_lender_borrow_and_repay_with_another_asset() public {
        vm.startPrank(user_agent);

        lender.borrow(address(usdc), 1000e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 1000e6);

        // simulate yield
        usdt.mint(user_agent, 1000e6);

        // repay the debt
        usdt.approve(env.infra.lender, 1000e6 + 10e6);
        lender.repay(address(usdt), 1000e6, user_agent);
    }

    function test_lender_borrow_and_repay_more_than_borrowed() public {
        vm.startPrank(user_agent);

        lender.borrow(address(usdc), 1000e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 1000e6);

        // simulate yield
        usdc.mint(user_agent, 1000e6);

        // repay the debt
        usdc.approve(env.infra.lender, 2000e6 + 10e6);
        lender.repay(address(usdc), 2000e6, user_agent);

        assertEq(usdc.balanceOf(user_agent), 1000e6);
    }

    function test_borrow_an_invalid_asset() public {
        vm.startPrank(user_agent);

        vm.expectRevert();
        lender.borrow(address(0), 1000e6, user_agent);

        MockERC20 invalidAsset = new MockERC20("InvalidAsset", "INV", 18);

        invalidAsset.mint(user_agent, 1000e6);

        vm.expectRevert();
        lender.borrow(address(invalidAsset), 1000e6, user_agent);
    }

    function test_borrow_more_than_one_asset() public {
        vm.startPrank(user_agent);

        lender.borrow(address(usdc), 1000e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 1000e6);

        lender.borrow(address(usdt), 1000e6, user_agent);
        assertEq(usdt.balanceOf(user_agent), 1000e6);
    }

    function test_lender_realize_interest() public {
        vm.startPrank(user_agent);

        lender.borrow(address(usdc), 300e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 300e6);

        _timeTravel(1 days);

        uint256 interest = interestDebtToken.balanceOf(user_agent);
        uint256 restakerInterest = restakerDebtToken.balanceOf(user_agent);
        uint256 principal = principalDebtToken.balanceOf(user_agent);

        uint256 totalInterest = interest + restakerInterest;
        uint256 totalDebt = principal + totalInterest;
        assertEq(totalDebt, 300e6 + totalInterest);

        uint256 feeAuctionBalBefore = usdc.balanceOf(address(cUSDFeeAuction));

        lender.realizeInterest(address(usdc), 1);

        uint256 feeAuctionBalAfter = usdc.balanceOf(address(cUSDFeeAuction));

        (,,,,,,,, uint256 realizedInterest,) = lender.reservesData(address(usdc));
        assertEq(realizedInterest, 1);

        lender.realizeInterest(address(usdc), interest - 1);

        feeAuctionBalAfter = usdc.balanceOf(address(cUSDFeeAuction));

        assertEq(feeAuctionBalAfter - feeAuctionBalBefore, interest);

        (,,,,,,,, realizedInterest,) = lender.reservesData(address(usdc));
        assertEq(realizedInterest, interest);

        interest = interestDebtToken.balanceOf(user_agent);
        restakerInterest = restakerDebtToken.balanceOf(user_agent);
        principal = principalDebtToken.balanceOf(user_agent);

        uint256 newTotalInterest = interest + restakerInterest;
        uint256 newTotalDebt = principal + newTotalInterest;
        assertEq(newTotalDebt, 300e6 + newTotalInterest);
    }

    function test_realize_restaker_interest() public {
        vm.startPrank(user_agent);

        lender.borrow(address(usdc), 300e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 300e6);

        _timeTravel(1 days);

        address networkRewards = env.symbiotic.networkRewards[0];

        uint256 restakerInterestBefore = restakerDebtToken.balanceOf(user_agent);

        lender.realizeRestakerInterest(user_agent, address(usdc), 1);

        uint256 rewardsBalance = usdc.balanceOf(networkRewards);
        assertEq(rewardsBalance, 1);

        lender.realizeRestakerInterest(user_agent, address(usdc), restakerInterestBefore - 1);

        rewardsBalance = usdc.balanceOf(networkRewards);
        assertEq(rewardsBalance, restakerInterestBefore);

        uint256 realizedRestakerInterest = lender.realizedRestakerInterest(address(user_agent), address(usdc));
        assertEq(realizedRestakerInterest, restakerInterestBefore);

        (uint principal, uint interest, uint restaker) = lender.debt(address(user_agent), address(usdc));
        uint256 totalDebt = principal + interest + restaker;

        usdc.mint(user_agent, totalDebt - principal);
        usdc.approve(address(lender), totalDebt);
        lender.repay(address(usdc), totalDebt, user_agent);

        uint256 restakerInterest = restakerDebtToken.balanceOf(user_agent);
        realizedRestakerInterest = lender.realizedRestakerInterest(address(user_agent), address(usdc));
        rewardsBalance = usdc.balanceOf(networkRewards);

        /// There should be no restaker interest left
        assertEq(restakerInterest, 0);
        /// There should be no realized restaker interest
        assertEq(realizedRestakerInterest, 0);
        /// Rewards should not have increased
        assertEq(rewardsBalance, restakerInterestBefore);
    }

    function test_borrow_payback_debt_tokens() public {
        vm.startPrank(user_agent);

        lender.borrow(address(usdc), 300e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 300e6);

        _timeTravel(1 days);

        uint256 interest = interestDebtToken.balanceOf(user_agent);
        uint256 restakerInterest = restakerDebtToken.balanceOf(user_agent);
        uint256 principal = principalDebtToken.balanceOf(user_agent);

        console.log("Principal Debt tokens:", principal);
        console.log("Restaker Debt tokens:", restakerInterest);
        console.log("Interest Debt tokens:", interest);

        uint256 totalInterest = interest + restakerInterest;
        uint256 totalDebt = principal + totalInterest;
        assertEq(totalDebt, 300e6 + totalInterest);

        usdc.mint(user_agent, totalInterest);

        // repay the debt
        usdc.approve(address(lender), totalDebt);
        lender.repay(address(usdc), principal, user_agent);

        assertDebtEq(0, interest, restakerInterest);

        lender.repay(address(usdc), restakerInterest, user_agent);

        assertDebtEq(0, interest, 0);

        lender.repay(address(usdc), interest, user_agent);

        assertDebtEq(0, 0, 0);
    }

    function test_borrow_utilization() public {
        vm.startPrank(env.symbiotic.users.vault_admin);
        _symbioticVaultDelegateToAgent(symbioticWethVault, env.symbiotic.networkAdapter, user_agent, 2e27);
        vm.stopPrank();

        vm.startPrank(user_agent);

        uint256 totalSupply = cUSD.totalSupplies(address(usdt));

        lender.borrow(address(usdt), totalSupply, user_agent);
        assertEq(usdt.balanceOf(user_agent), totalSupply);

        assertEq(cUSD.utilization(address(usdt)), 1e27);
        assertEq(cUSD.totalBorrows(address(usdt)), totalSupply);
        assertEq(cUSD.availableBalance(address(usdt)), 0);

        usdt.approve(address(lender), totalSupply);
        lender.repay(address(usdt), totalSupply, user_agent);

        assertEq(cUSD.utilization(address(usdt)), 0);
        assertEq(cUSD.totalBorrows(address(usdt)), 0);
        assertEq(cUSD.availableBalance(address(usdt)), totalSupply);

        lender.borrow(address(usdt), totalSupply / 2, user_agent);
        assertEq(cUSD.utilization(address(usdt)), 0.5e27);
        assertEq(cUSD.totalBorrows(address(usdt)), totalSupply / 2);
        assertEq(cUSD.availableBalance(address(usdt)), totalSupply / 2);

        // since we updated the index current should be 0
        assertEq(cUSD.currentUtilizationIndex(address(usdt)), 0);
    }

    function assertDebtEq(uint256 principalDebt, uint256 interestDebt, uint256 restakerDebt) internal view {
        (uint256 principalDebtView, uint256 interestDebtView, uint256 restakerDebtView) =
            lender.debt(user_agent, address(usdc));
        assertEq(principalDebtView, principalDebt);
        assertEq(interestDebtView, interestDebt);
        assertEq(restakerDebtView, restakerDebt);

        assertEq(principalDebtToken.balanceOf(user_agent), principalDebt);
        assertEq(interestDebtToken.balanceOf(user_agent), interestDebt);
        assertEq(restakerDebtToken.balanceOf(user_agent), restakerDebt);
    }
}
