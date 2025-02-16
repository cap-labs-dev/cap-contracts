// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Lender } from "../../contracts/lendingPool/Lender.sol";

import { InterestDebtToken } from "../../contracts/lendingPool/tokens/InterestDebtToken.sol";
import { PrincipalDebtToken } from "../../contracts/lendingPool/tokens/PrincipalDebtToken.sol";
import { RestakerDebtToken } from "../../contracts/lendingPool/tokens/RestakerDebtToken.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";

import { MockNetworkMiddleware } from "../mocks/MockNetworkMiddleware.sol";
import { console } from "forge-std/console.sol";

contract LenderBorrowTest is TestDeployer {
    address user_agent;

    function useMockBackingNetwork() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);

        user_agent = _getRandomAgent();
        MockNetworkMiddleware(env.symbiotic.networkAdapter.networkMiddleware).setMockCoverage(user_agent, 1e50);

        // have something to repay
        vm.startPrank(user_agent);
        lender.borrow(address(usdc), 100e6, user_agent);
        usdc.approve(address(lender), 100e6);
        vm.stopPrank();
    }

    function test_gas_lender_borrow() public {
        vm.startPrank(user_agent);

        lender.borrow(address(usdc), 100e6, user_agent);
        vm.snapshotGasLastCall("Lender.gas.t", "simple_borrow");
    }

    function test_gas_lender_repay() public {
        vm.startPrank(user_agent);

        lender.repay(address(usdc), 10e6, user_agent);
        vm.snapshotGasLastCall("Lender.gas.t", "simple_repay");
    }
}
