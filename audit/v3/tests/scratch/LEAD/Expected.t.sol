// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { P14_Whitelisted } from "./P14_Whitelisted.t.sol";
import { P6_FixedCrossNotional } from "./P6_FixedCrossNotional.t.sol";
import { P8_BorrowerOptIn } from "./P8_BorrowerOptIn.t.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// Intended-behaviour assertions. Each of these FAILS on HEAD; they are the proofs in the schema sense.
contract Expected_P14 is P14_Whitelisted {
    function test_EXPECTED_seniorStaysLockedWhenOwnerAppendsJunior() public {
        FloatingMarket(market).setFixedCreditLimit(500_000e18);
        vm.prank(eve);
        FloatingMarket(market).borrow(eve, type(uint256).max);
        Tranche senior = Tranche(tranches[0]);
        MockERC20 alt = _newCollateral("Alt", "ALT", 18, 1e18);
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e27;
        w[1] = 0.5e27;
        vm.prank(eve);
        address junior = registry.createTranche(market, address(alt), w);
        uint64 depRole = accessManager.getTargetFunctionRole(junior, IERC4626.deposit.selector);
        vm.prank(eve);
        accessManager.grantRole(depRole, eve, 0);
        alt.mint(eve, 1_000_000e18);
        vm.startPrank(eve);
        alt.approve(address(vault), type(uint256).max);
        vault.deposit(address(alt), 1_000_000e18, eve);
        vault.setOperator(junior, true);
        Tranche(junior).deposit(1_000_000e18, eve);
        vm.stopPrank();
        // expected: the collateral GOVERNOR sized against cannot leave while the line is drawn
        assertLt(senior.unlockedSupply(), senior.totalSupply(), "senior collateral must stay locked");
    }
}

contract Expected_P8 is P8_BorrowerOptIn {
    function test_EXPECTED_borrowerEarnsNoLiquidityPremium() public {
        vm.startPrank(defaultBorrower);
        b.market.borrow(defaultBorrower, 1_000_000e18);
        stablecoin.optIn();
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);
        b.market.chargePremium();
        vm.warp(block.timestamp + 7 days);
        vm.prank(defaultBorrower);
        uint256 got = stablecoin.claim(defaultBorrower);
        assertEq(got, 0, "credit-backed balance must not earn the liquidity premium");
    }
}

contract Expected_P6 is P6_FixedCrossNotional {
    function test_EXPECTED_fixedPremiumIndependentOfSameBlockFloatingNotional() public {
        uint256 P = 500_000e18;
        (uint256 l0, uint256 u0) = fx.premiumForBorrow(P, 30 days);
        vm.prank(floatBorrower);
        fl.borrow(floatBorrower, 2_000_000e18);
        (uint256 l1, uint256 u1) = fx.premiumForBorrow(P, 30 days);
        vm.prank(floatBorrower);
        fl.repay(type(uint256).max);
        assertEq(l1 + u1, l0 + u0, "a transient floating draw must not reprice a fixed draw");
    }
}
