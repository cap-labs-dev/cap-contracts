// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// P6: a fixed draw is charged the catch-up on *global* unsmoothed credit, including floating credit that
/// already pays the higher rate through its own index (double charge), and a same-block floating
/// borrow+repay sandwich pays nothing while raising the fixed borrower's premium.
contract P6_FixedCrossNotional is CapDeployer {
    address floatBorrower = makeAddr("floatBorrower");
    address fixedBorrower = makeAddr("fixedBorrower");
    address lender = makeAddr("lender");
    FloatingMarket fl;
    FixedMarket fx;

    function setUp() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = true;
        cfg.defaultFixedCreditLimit = 10_000_000e18;
        _deployCapWithConfig(cfg);
        (address m1,,) = _createMarket("float", defaultMarketOwner, floatBorrower);
        fl = FloatingMarket(m1);
        _configureMarketRates(fl);
        (address m2, address t0,) = _createFixedMarket("fixed", defaultMarketOwner, fixedBorrower);
        fx = FixedMarket(m2);
        _configureMarketRates(FloatingMarket(m2));
        // collateral for both
        address[] memory ts = new address[](0);
        ts;
        _fundTranche(_trancheOf(m1), makeAddr("u1"), 5_000_000e18);
        _fundTranche(t0, makeAddr("u2"), 5_000_000e18);
        _depositStable(lender, 2_000_000e18); // reserve so utilization is below 100%
        // let the utilization EMA absorb the reserve deposit, otherwise every quote sits at 100% util
        vm.warp(block.timestamp + 3 days);
        irm.updateLiquidityRate();
    }

    function _trancheOf(address m) internal view returns (address) {
        return FloatingMarket(m).tranches()[0].tranche;
    }

    function _quote(uint256 P) internal view returns (uint256 total) {
        (uint256 l, uint256 u) = fx.premiumForBorrow(P, 30 days);
        total = l + u;
    }

    function test_P6_fixedPaysCatchUpOnFloatingNotional() public {
        uint256 P = 500_000e18;
        uint256 quoteClean = _quote(P);

        // an honest floating borrower draws C in the same averaging window
        vm.prank(floatBorrower);
        fl.borrow(floatBorrower, 500_000e18);
        uint256 quoteWithFloating = _quote(P);

        // same C but absorbed into the average (window fully elapsed): no catch-up
        vm.warp(block.timestamp + 2 days);
        irm.updateLiquidityRate();
        uint256 quoteAbsorbed = _quote(P);

        emit log_named_decimal_uint("fixed premium, clean book", quoteClean, 18);
        emit log_named_decimal_uint("fixed premium, floating C=500k drawn this window", quoteWithFloating, 18);
        emit log_named_decimal_uint("fixed premium, same C absorbed into average", quoteAbsorbed, 18);
        emit log_named_decimal_uint(
            "overcharge attributable to someone else's floating notional", quoteWithFloating - quoteAbsorbed, 18
        );
        assertGt(quoteWithFloating, quoteAbsorbed);
        // and the floating loan itself pays the higher rate through its index: the pot is paid twice for C
        uint256 idx0 = fl.index();
        vm.warp(block.timestamp + 30 days);
        assertGt(fl.index(), idx0);
    }

    function test_P6_sameBlockSandwichCostsAttackerNothing() public {
        uint256 P = 500_000e18;
        uint256 quoteClean = _quote(P);
        // attacker: floating borrow, victim fixed draw, attacker repay — all one block
        vm.prank(floatBorrower);
        fl.borrow(floatBorrower, 2_000_000e18);
        uint256 quoteSandwiched = _quote(P);
        vm.prank(fixedBorrower);
        (, uint256 drawn) = fx.borrow(fixedBorrower, P, 30 days);
        uint256 victimDebt = fx.debt(0);
        vm.prank(floatBorrower);
        uint256 repaid = fl.repay(type(uint256).max);
        emit log_named_decimal_uint("attacker floating repaid (== borrowed, zero premium)", repaid, 18);
        emit log_named_decimal_uint("victim premium, clean", quoteClean, 18);
        emit log_named_decimal_uint("victim premium, sandwiched", quoteSandwiched, 18);
        emit log_named_decimal_uint("victim debt recorded", victimDebt - drawn, 18);
        assertApproxEqAbs(repaid, 2_000_000e18, 1, "attacker paid zero premium");
        assertGt(victimDebt - drawn, quoteClean, "victim overcharged");
    }
}
