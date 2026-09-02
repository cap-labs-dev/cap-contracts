// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @title LockedValueTest
/// @notice The market computes locked capital in USD while tranches hold collateral tokens, so a
/// tranche has to price the locked value back into assets before deciding what is redeemable.
/// These cases use collateral away from $1 so a missing conversion cannot pass unnoticed.
contract LockedValueTest is CapDeployer {
    function _marketAtPrice(uint256 price) internal returns (FloatingMarket market, address senior, address junior) {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.collateralPrice = price;
        _deployCapWithConfig(cfg);

        address marketAddr;
        (marketAddr, senior, junior) = _createMarket("M");
        market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        market.setFixedCreditLimit(100_000e18);
        _fundTranche(senior, makeAddr("senior"), 1_000e18);
        _fundTranche(junior, makeAddr("junior"), 1_000e18);
    }

    /// Collateral at $0.50: $500 of debt needs $714 of backing, more than the junior's entire $500
    /// of capital, so nothing in the junior may be redeemed.
    function test_juniorFullyLockedWhenBackingExceedsItsCapital() public {
        (FloatingMarket market,, address junior) = _marketAtPrice(0.5e18);
        assertEq(market.totalCapital(), 1_000e18, "2000 tokens at $0.50");

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        // required backing value = debt / (lt - buffer) = 500 / 0.7
        assertApproxEqAbs(market.lockedValue(junior), 714285714285714285714, 1, "junior locks the whole requirement");
        assertGt(market.lockedValue(junior), Tranche(junior).totalCapital(), "requirement exceeds its capital");

        assertEq(Tranche(junior).unlockedSupply(), 0, "junior must be fully locked");
        assertEq(Tranche(junior).maxRedeem(makeAddr("junior")), 0, "nothing redeemable");
    }

    /// An underwriter must never be able to exit collateral that is backing live debt, which shows
    /// up as the credit limit dropping below outstanding debt.
    function test_redemptionCannotPushCreditLimitBelowDebt() public {
        (FloatingMarket market,, address junior) = _marketAtPrice(0.5e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        uint256 redeemable = Tranche(junior).maxRedeem(makeAddr("junior"));
        if (redeemable > 0) {
            vm.prank(makeAddr("junior"));
            Tranche(junior).redeem(redeemable, makeAddr("junior"), makeAddr("junior"));
        }

        assertGe(market.creditLimit(), market.totalDebt(), "credit limit must still cover the debt");
    }

    /// Above $1 the senior has spare capacity once the junior covers the requirement, and the
    /// unlocked amount must be priced in tokens rather than dollars.
    function test_seniorUnlockedAmountIsPricedInTokens() public {
        (FloatingMarket market, address senior, address junior) = _marketAtPrice(2e18);
        assertEq(market.totalCapital(), 4_000e18, "2000 tokens at $2");

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 1_000e18);

        // requirement is 1000 / 0.7 = $1428.57; the junior holds $2000 so it absorbs all of it
        assertApproxEqAbs(market.lockedValue(junior), 1428571428571428571428, 1, "junior locks the requirement");
        assertEq(market.lockedValue(senior), 0, "junior alone covers it, senior is free");
        assertEq(Tranche(senior).unlockedSupply(), Tranche(senior).totalSupply(), "senior fully unlocked");

        // the junior locks $1428.57 of value = 714.29 tokens out of its 1000
        uint256 expectedUnlocked = 1_000e18 - 714285714285714285714;
        assertApproxEqAbs(Tranche(junior).unlockedSupply(), expectedUnlocked, 1e6, "junior unlocked in tokens");
    }

    /// No debt means nothing is locked, at any price.
    function test_noDebtLeavesEverythingUnlocked() public {
        (FloatingMarket market, address senior, address junior) = _marketAtPrice(0.5e18);
        assertEq(market.totalDebt(), 0, "no debt");
        assertEq(market.lockedValue(senior), 0, "senior free");
        assertEq(market.lockedValue(junior), 0, "junior free");
        assertEq(Tranche(junior).unlockedSupply(), Tranche(junior).totalSupply(), "all unlocked");
    }

    /// lockedValue divides by lt - buffer, so the setters must keep the buffer below lt.
    function test_buffer_cannotBeRaisedToOrAboveLt() public {
        (FloatingMarket market,,) = _marketAtPrice(1e18);
        assertEq(market.lt(), 0.8e27, "fixture lt");

        vm.expectRevert(IBaseMarket.InvalidBuffer.selector);
        market.setBuffer(0.8e27);

        vm.expectRevert(IBaseMarket.InvalidBuffer.selector);
        market.setBuffer(0.9e27);

        market.setBuffer(0.79e27); // still valid
    }

    function test_lt_cannotBeDroppedToOrBelowBuffer() public {
        (FloatingMarket market,,) = _marketAtPrice(1e18);
        assertEq(market.buffer(), 0.1e27, "fixture buffer");

        vm.expectRevert(IBaseMarket.InvalidLt.selector);
        market.setLt(0.1e27);

        vm.expectRevert(IBaseMarket.InvalidLt.selector);
        market.setLt(0.05e27);

        // dropping lt below ltv is still allowed; that just makes the market unhealthy
        market.setLt(0.2e27);
        assertLt(market.lt(), market.ltv(), "lt below ltv is a permitted guardian action");
    }

    function test_targetHealth_atLeast1_25AndAboveLt() public {
        (FloatingMarket market,,) = _marketAtPrice(1e18);
        assertEq(market.lt(), 0.8e27, "fixture lt");
        assertEq(market.targetHealth(), 1.25e27, "fixture targetHealth");

        vm.expectRevert(IBaseMarket.InvalidTargetHealth.selector);
        market.setTargetHealth(1e27);

        vm.expectRevert(IBaseMarket.InvalidTargetHealth.selector);
        market.setTargetHealth(1.24e27);

        market.setTargetHealth(1.25e27);
        market.setTargetHealth(1.5e27);
        assertEq(market.targetHealth(), 1.5e27);

        market.setLt(1e27);
        assertLt(market.lt(), market.targetHealth(), "lt stays strictly below targetHealth");
    }
}
