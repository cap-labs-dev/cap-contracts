// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IFixedMarket } from "../../contracts/interfaces/IFixedMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { WadRayMath } from "../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice {premiumForBorrow} and {maxPrincipal} over a loan's remaining term match {borrowMore},
/// including a grandfathered remainder above a since-lowered maximum.
contract FixedTopUpQuoteTest is CapDeployer {
    FixedMarket internal market;
    uint256 internal id;

    function setUp() public {
        _deployCap();
        (address deployed, address senior,) = _createFixedMarket("Top-up quotes");
        market = FixedMarket(deployed);
        market.setUnderwriterRate(0.2e27);
        irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        _setMaxCapital(market, 10_000e18);
        _fundTranche(senior, makeAddr("senior"), 10_000e18);
        _depositStable(makeAddr("reserve holder"), 10_000e18);
        vm.warp(block.timestamp + 20 * irm.averagingPeriod());
        irm.updateLiquidityRate();

        vm.prank(defaultBorrower);
        (id,) = market.borrow(defaultBorrower, 100e18, 30 days, type(uint256).max);
    }

    /// @dev The audit's example: 30 days remain, the maximum drops to 7 days, no liquidity
    /// interest and a 20% underwriting rate. The quote and the charge are both 30 days.
    function test_topUpQuoteChargesFullRemainingTermAfterMaximumLowered() public {
        irm.setLiquiditySlopes(IInterestRateModel.Slopes({ base: 0, slope0: 0, slope1: 0, kink: 0.8e27 }));
        market.setTermLimits(7 days, 1 days);
        uint256 remaining = _remaining();
        assertEq(remaining, 30 days);

        uint256 quote = _quote(100e18, remaining);
        assertEq(quote, Math.mulDiv(WadRayMath.rayMul(100e18, 0.2e27), 30 days, 365 days));
        assertApproxEqAbs(quote, 1.64384e18, 0.00001e18);

        vm.expectRevert(abi.encodeWithSelector(IFixedMarket.PremiumExceedsLimit.selector, quote, quote - 1));
        vm.prank(defaultBorrower);
        market.borrowMore(id, defaultBorrower, 100e18, quote - 1);

        uint256 debtBefore = market.debt(id);
        vm.prank(defaultBorrower);
        assertEq(market.borrowMore(id, defaultBorrower, 100e18, quote), 100e18);
        assertEq(market.debt(id) - debtBefore, 100e18 + quote, "execution charges exactly the quote");
    }

    function test_topUpMaxPrincipalFitsExecutionAfterMaximumLowered() public {
        market.setTermLimits(7 days, 1 days);
        uint256 remaining = _remaining();
        uint256 sized = market.maxPrincipal(remaining);
        assertGt(sized, 0);
        assertLt(sized, market.maxPrincipal(type(uint256).max), "the remainder costs more than the maximum");

        uint256 quote = _quote(sized, remaining);
        uint256 debtBefore = market.debt(id);
        vm.prank(defaultBorrower);
        assertEq(market.borrowMore(id, defaultBorrower, type(uint256).max, quote), sized);
        assertEq(market.debt(id) - debtBefore, sized + quote);
        assertLe(market.totalDebt(), market.creditLimit());
    }

    function _remaining() internal view returns (uint256) {
        return market.expiry(id) - block.timestamp;
    }

    function _quote(uint256 principal, uint256 term) internal view returns (uint256 premium) {
        (uint256 liquidity, uint256 underwriting) = market.premiumForBorrow(principal, term);
        premium = liquidity + underwriting;
    }
}
