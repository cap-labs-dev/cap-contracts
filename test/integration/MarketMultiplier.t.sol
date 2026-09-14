// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @title MarketMultiplierTest
/// @notice The market multiplier raises floating growth to `m` and scales the fixed liquidity
/// rate by `m`. Realising premium must not change what is owed, and a new `m` applies only
/// going forward.
contract MarketMultiplierTest is CapDeployer {
    uint256 internal constant PRINCIPAL = 1000e18;

    function setUp() public {
        _deployCap();
    }

    function _flatLiquidity(uint256 ratePerYear) internal {
        irm.setLiquiditySlopes(IInterestRateModel.Slopes({ base: ratePerYear, slope0: 0, slope1: 0, kink: 0.8e27 }));
    }

    function _readyFloating(string memory name, uint256 multiplier) internal returns (FloatingMarket market) {
        (address marketAddr, address senior,) = _createMarket(name);
        market = FloatingMarket(marketAddr);
        market.setUnderwriterRate(0);
        market.setMarketMultiplier(multiplier);
        _fundTranche(senior, makeAddr(string.concat(name, "-lp")), 10_000e18);
    }

    function _readyFixed(string memory name, uint256 multiplier) internal returns (FixedMarket market) {
        (address marketAddr, address senior,) = _createFixedMarket(name);
        market = FixedMarket(marketAddr);
        market.setUnderwriterRate(0);
        market.setMarketMultiplier(multiplier);
        _setFixedCreditLimit(market, 10_000e18);
        _fundTranche(senior, makeAddr(string.concat(name, "-lp")), 10_000e18);
    }

    function _borrowFloating(FloatingMarket market) internal {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, PRINCIPAL);
    }

    /// 1.5x is the geometric mean of 1x and 2x: `(I)^1.5` between `I` and `I^2`.
    function test_oneAndAHalfRaisesGrowthToOneAndAHalf() public {
        _flatLiquidity(0.1e27);
        FloatingMarket one = _readyFloating("one", 1e27);
        FloatingMarket oneAndAHalf = _readyFloating("oneAndAHalf", 1.5e27);
        _borrowFloating(one);
        _borrowFloating(oneAndAHalf);

        vm.warp(block.timestamp + 365 days);

        uint256 debt1 = one.totalDebt();
        uint256 debt15 = oneAndAHalf.totalDebt();
        assertGt(debt1, PRINCIPAL);
        // (d15 / P)^2 == (d1 / P)^3
        assertApproxEqRel(debt15 * debt15 / PRINCIPAL, debt1 * debt1 / PRINCIPAL * debt1 / PRINCIPAL, 1e15);
    }

    function test_fractionalRealisingDoesNotChangeWhatIsOwed() public {
        _flatLiquidity(0.1e27);
        FloatingMarket quiet = _readyFloating("quiet", 1.5e27);
        FloatingMarket busy = _readyFloating("busy", 1.5e27);
        _borrowFloating(quiet);
        _borrowFloating(busy);

        for (uint256 i; i < 12; ++i) {
            vm.warp(block.timestamp + 30 days);
            busy.chargePremium();
        }
        vm.warp(block.timestamp + 5 days);
        assertApproxEqRel(quiet.totalDebt(), busy.totalDebt(), 1e12);
    }

    function test_viewDebtMatchesRealisedDebt() public {
        _flatLiquidity(0.1e27);
        FloatingMarket market = _readyFloating("view", 1.5e27);
        _borrowFloating(market);

        vm.warp(block.timestamp + 365 days);
        uint256 viewed = market.totalDebt();
        (uint256 viewedLiquidity,) = market.premiumIndices();
        market.chargePremium();
        (uint256 realisedLiquidity,) = market.premiumIndices();

        assertEq(market.totalDebt(), viewed);
        assertEq(realisedLiquidity, viewedLiquidity);
    }

    /// Changing `m` checkpoints at the old factor first, so outstanding debt does not jump, and
    /// only later growth sees the new exponent.
    function test_newMultiplierAppliesOnlyGoingForward() public {
        _flatLiquidity(0.1e27);
        FloatingMarket market = _readyFloating("step", 1e27);
        _borrowFloating(market);

        vm.warp(block.timestamp + 365 days);
        uint256 afterOne = market.totalDebt();
        uint256 globalAtSet = irm.liquidityIndex();
        market.setMarketMultiplier(2e27);
        assertApproxEqAbs(market.totalDebt(), afterOne, 1);

        vm.warp(block.timestamp + 365 days);
        uint256 globalNow = irm.liquidityIndex();
        // 2x squares whatever the protocol grew after the change, not the first year's factor
        assertApproxEqRel(market.totalDebt(), afterOne * globalNow / globalAtSet * globalNow / globalAtSet, 1e15);
    }

    function test_underwriterGrowthIgnoresMultiplier() public {
        _flatLiquidity(0);
        FloatingMarket one = _readyFloating("uw-one", 1e27);
        FloatingMarket two = _readyFloating("uw-two", 2e27);
        one.setUnderwriterRate(0.2e27);
        two.setUnderwriterRate(0.2e27);
        _borrowFloating(one);
        _borrowFloating(two);

        vm.warp(block.timestamp + 365 days);
        assertApproxEqRel(one.totalDebt(), two.totalDebt(), 1e12);
    }

    function test_fixedLiquidityPremiumScalesLinearly() public {
        _flatLiquidity(0.1e27);
        FixedMarket one = _readyFixed("fx-one", 1e27);
        FixedMarket oneAndAHalf = _readyFixed("fx-15", 1.5e27);
        FixedMarket two = _readyFixed("fx-two", 2e27);

        vm.startPrank(defaultBorrower);
        (uint256 id1,) = one.borrow(defaultBorrower, PRINCIPAL, 30 days);
        (uint256 id15,) = oneAndAHalf.borrow(defaultBorrower, PRINCIPAL, 30 days);
        (uint256 id2,) = two.borrow(defaultBorrower, PRINCIPAL, 30 days);
        vm.stopPrank();

        uint256 premium1 = one.debt(id1) - PRINCIPAL;
        uint256 premium15 = oneAndAHalf.debt(id15) - PRINCIPAL;
        uint256 premium2 = two.debt(id2) - PRINCIPAL;
        assertGt(premium1, 0);
        assertApproxEqRel(premium15, premium1 * 3 / 2, 1e15);
        assertApproxEqRel(premium2, premium1 * 2, 1e15);
    }

    function test_fixedUnderwriterPremiumIgnoresMultiplier() public {
        _flatLiquidity(0);
        FixedMarket one = _readyFixed("fx-uw-one", 1e27);
        FixedMarket two = _readyFixed("fx-uw-two", 2e27);
        one.setUnderwriterRate(0.2e27);
        two.setUnderwriterRate(0.2e27);

        vm.startPrank(defaultBorrower);
        (uint256 id1,) = one.borrow(defaultBorrower, PRINCIPAL, 30 days);
        (uint256 id2,) = two.borrow(defaultBorrower, PRINCIPAL, 30 days);
        vm.stopPrank();

        assertApproxEqRel(one.debt(id1), two.debt(id2), 1e15);
    }

    function test_oneAndAHalfIsInsideTheBand() public {
        FloatingMarket market = _readyFloating("band", 1e27);
        market.setMarketMultiplier(1.5e27);
        assertEq(market.marketMultiplier(), 1.5e27);
    }

    function test_multiplierOutsideTheBandReverts() public {
        FloatingMarket market = _readyFloating("bounds", 1e27);
        vm.expectRevert(IInterestRateModel.InvalidMultiplier.selector);
        market.setMarketMultiplier(0.5e27);
        vm.expectRevert(IInterestRateModel.InvalidMultiplier.selector);
        market.setMarketMultiplier(3e27);
    }
}
