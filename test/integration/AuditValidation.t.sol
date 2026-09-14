// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IFixedMarket } from "../../contracts/interfaces/IFixedMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice Pins documented audit behavior. M-02 is the post-fix invariant; overdue repay
/// leaves arrears to a keeper extend; a lowered max term refuses live extend with InvalidTerm.
contract AuditValidationTest is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function test_guardianLtReductionConstrainsFloatingBorrow() public {
        (address m, address t,) = _createMarket("risk limits");
        FloatingMarket market = FloatingMarket(m);
        _setMaxCapitalOn(market, t, type(uint256).max);
        _fundTranche(t, makeAddr("supplier"), 2_000e18);
        market.setLt(0.2e27);
        assertEq(market.creditLimit(), 400e18);
        vm.prank(defaultBorrower);
        vm.expectRevert(IBaseMarket.InsufficientLiquidity.selector);
        market.borrow(defaultBorrower, 900e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);
        assertGe(market.healthiness(), 1e27);
    }

    function test_audit_overdueRepaymentDoesNotSettleArrears() public {
        (address m, address t,) = _createFixedMarket("maturity");
        FixedMarket market = FixedMarket(m);
        market.setUnderwriterRate(0.2e27);
        _setBorrowableOn(market, t, 1_000e18);
        _fundTranche(t, makeAddr("supplier"), 10_000e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, 500e18, 1 days);
        uint256 initialDebt = market.debt(id);
        _depositStable(defaultBorrower, 100e18);
        vm.warp(market.expiry(id) + 365 days);
        assertEq(market.debt(id), initialDebt);
        vm.prank(defaultBorrower);
        assertEq(market.repay(id, type(uint256).max), initialDebt);
    }

    function test_audit_lowerMaximumTermBreaksLiveExtension() public {
        (address m, address t,) = _createFixedMarket("term changes");
        FixedMarket market = FixedMarket(m);
        _setBorrowableOn(market, t, 1_000e18);
        _fundTranche(t, makeAddr("supplier"), 10_000e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, 500e18, 30 days);
        uint256 expiryBefore = market.expiry(id);
        market.setTermLimits(7 days, 1 days);
        vm.prank(defaultBorrower);
        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        market.extend(id, 1 days);
        assertEq(market.expiry(id), expiryBefore, "grandfathered expiry is unchanged");
        vm.warp(expiryBefore - 6 days);
        vm.prank(defaultBorrower);
        uint256 added = market.extend(id, type(uint256).max);
        assertEq(added, 1 days, "room opens once remaining sits under the new maximum");
        assertEq(market.expiry(id), expiryBefore + 1 days);
    }
}
