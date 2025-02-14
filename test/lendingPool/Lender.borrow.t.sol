// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { InterestDebtToken } from "../../contracts/lendingPool/tokens/InterestDebtToken.sol";
import { PrincipalDebtToken } from "../../contracts/lendingPool/tokens/PrincipalDebtToken.sol";
import { RestakerDebtToken } from "../../contracts/lendingPool/tokens/RestakerDebtToken.sol";

import { TestDeployer } from "../deploy/TestDeployer.sol";

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

        uint256 assetIndex = _getAssetIndex(usdVault, address(usdc));
        principalDebtToken = PrincipalDebtToken(usdVault.principalDebtTokens[assetIndex]);
        restakerDebtToken = RestakerDebtToken(usdVault.restakerDebtTokens[assetIndex]);
        interestDebtToken = InterestDebtToken(usdVault.interestDebtTokens[assetIndex]);
    }

    function test_lender_borrow_and_repay() public {
        vm.startPrank(user_agent);

        uint256 backingBefore = usdc.balanceOf(address(cUSD));

        lender.borrow(address(usdc), 1000e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 1000e6);

        // simulate yield
        usdc.mint(user_agent, 1000e6);

        // repay the debt
        usdc.approve(env.infra.lender, 1000e6 + 10e6);
        lender.repay(address(usdc), 1000e6, user_agent);
        assertGe(usdc.balanceOf(address(cUSD)), backingBefore);
    }

    function test_lender_borrow_and_repay_debt_tokens() public {
        vm.startPrank(user_agent);

        uint256 backingBefore = usdc.balanceOf(address(cUSD));

        lender.borrow(address(usdc), 1000e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), 1000e6);

        // we should have some debt tokens attached to the user
        assertEq(principalDebtToken.balanceOf(user_agent), 1000e6);
        assertEq(interestDebtToken.balanceOf(user_agent), 0);
        assertEq(restakerDebtToken.balanceOf(user_agent), 0);
        (uint256 interestPerSecond, uint256 lastRestakerUpdate) = restakerDebtToken.agent(user_agent);
        assertEq(interestPerSecond, 50000000);
        assertEq(lastRestakerUpdate, block.timestamp);
        (uint256 storedIndex, uint256 lastInterestUpdate) = interestDebtToken.agent(user_agent);
        assertEq(storedIndex, 1e27);
        assertEq(lastInterestUpdate, block.timestamp);

        _timeTravel(3 hours);

        // balances should accrue interest over time
        assertEq(principalDebtToken.balanceOf(user_agent), 1000e6);
        assertEq(interestDebtToken.balanceOf(user_agent), 68_495);
        assertEq(restakerDebtToken.balanceOf(user_agent), 0);
        (interestPerSecond, lastRestakerUpdate) = restakerDebtToken.agent(user_agent);
        assertEq(interestPerSecond, 50000000);
        assertEq(lastRestakerUpdate, block.timestamp - 3 hours);
        (storedIndex, lastInterestUpdate) = interestDebtToken.agent(user_agent);
        assertEq(storedIndex, 1e27);
        assertEq(lastInterestUpdate, block.timestamp - 3 hours);

        // simulate yield
        usdc.mint(user_agent, 1_000_000e6);
        usdc.approve(env.infra.lender, 1_000_000e6);

        // repay some of the debt
        lender.repay(address(usdc), 100e6, user_agent);

        // principal debt should be repaid first
        assertEq(principalDebtToken.balanceOf(user_agent), 900e6);
        assertEq(interestDebtToken.balanceOf(user_agent), 68_495);
        assertEq(restakerDebtToken.balanceOf(user_agent), 0);

        // interest debt should be repaid next
        lender.repay(address(usdc), 900e6 + 8495, user_agent);
        assertEq(principalDebtToken.balanceOf(user_agent), 0);
        assertEq(interestDebtToken.balanceOf(user_agent), 60_000);
        assertEq(restakerDebtToken.balanceOf(user_agent), 0);

        // cannot repay more than the debt
        uint256 balanceBefore = usdc.balanceOf(user_agent);
        lender.repay(address(usdc), 100e6, user_agent);
        assertEq(usdc.balanceOf(user_agent), balanceBefore - 60_000);
    }
}
