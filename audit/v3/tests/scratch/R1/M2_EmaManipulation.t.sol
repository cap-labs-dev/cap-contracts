// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 M-2 (E2 / R1_M2_EmaManipulation). A par, fee-less, instantly reversible
/// cUSD deposit held for one averaging window dilutes the time-weighted utilization the fixed-term
/// premium is priced off. HEAD: `averageUtilizationAfterMint` (InterestRateModel.sol:227-239) adds
/// unabsorbed CREDIT to both sides; a reserve-only deposit is still absorbed by the supply average.
/// API changes: `redeem` -> `instantRedeem`; the "band" test now asserts instead of `assertTrue(false)`.
contract R1_M2_EmaManipulation is CapDeployer {
    using WadRayMath for uint256;

    uint256 internal constant RESERVE = 2_000_000e18;
    uint256 internal constant CREDIT = 8_000_000e18; // 80% utilization (the kink)
    uint256 internal constant LOAN = 1_000_000e18;
    uint256 internal constant PARK = 10_000_000e18;

    address internal lp = makeAddr("lp");
    address internal attacker;
    address internal underwriter = makeAddr("underwriter");
    FixedMarket internal market;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        irm.setLiquiditySlopes(capConfig.liquiditySlopes); // base 5%, slope0 5%, slope1 10%, kink 80%
        attacker = defaultBorrower;

        (address m, address t0,) = _createFixedMarket("fixed");
        market = FixedMarket(m);
        market.setUnderwriterRate(0); // isolate the liquidity premium
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(t0, underwriter, 20_000_000e18);

        _depositStable(lp, RESERVE);
        _mintStable(makeAddr("other-borrower"), CREDIT);
        skip(30 * irm.averagingPeriod());
        assertApproxEqRel(irm.averageUtilization(), 0.8e27, 1e12, "honest average utilization is at the kink");
    }

    function _borrowMaxTerm(uint256 loan) internal returns (uint256 premium) {
        vm.prank(attacker);
        (uint256 id, uint256 principal) = market.borrow(attacker, loan, type(uint256).max);
        premium = market.debt(id) - principal;
    }

    function _pct(uint256 part, uint256 whole) internal pure returns (uint256 bps) {
        bps = whole == 0 ? 0 : part * 10_000 / whole;
    }

    function test_parkedDepositBuysADiscountOnTheWholeTerm() public {
        uint256 period = irm.averagingPeriod();

        uint256 snap = vm.snapshotState();
        uint256 honestPremium = _borrowMaxTerm(LOAN);
        vm.revertToState(snap);

        _depositStable(attacker, PARK);
        skip(period);
        emit log_named_decimal_uint("average utilization after 1 window parked", irm.averageUtilization(), 27);
        uint256 attackedPremium = _borrowMaxTerm(LOAN);
        vm.prank(attacker);
        uint256 redeemed = stablecoin.instantRedeem(PARK, attacker, attacker);
        assertEq(redeemed, PARK, "the parked USDC comes straight back at par");

        uint256 saved = honestPremium - attackedPremium;
        uint256 cost = PARK * period / 365 days / 10;
        emit log_named_uint("averaging period (s)", period);
        emit log_named_decimal_uint("honest 30-day liquidity premium (cUSD)", honestPremium, 18);
        emit log_named_decimal_uint("manipulated premium (cUSD)", attackedPremium, 18);
        emit log_named_decimal_uint("lenders lose (cUSD)", saved, 18);
        emit log_named_uint("discount (bps of honest)", _pct(saved, honestPremium));
        emit log_named_decimal_uint("attacker capital cost at 10% APR (cUSD)", cost, 18);
        emit log_named_uint("profit multiple", saved / (cost == 0 ? 1 : cost));

        assertEq(attackedPremium, honestPremium, "a fully reversible deposit repriced a 30-day loan");
    }

    function test_bandDoesNotChangeTheOutcome() public {
        uint256[3] memory periods = [uint256(5 minutes), 1 hours, 1 days];
        bool anyDiscount;
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            irm.setAveragingPeriod(periods[i]);
            skip(30 * periods[i]);

            uint256 inner = vm.snapshotState();
            uint256 honest = _borrowMaxTerm(LOAN);
            vm.revertToState(inner);

            _depositStable(attacker, PARK);
            skip(periods[i]);
            uint256 attacked = _borrowMaxTerm(LOAN);
            uint256 cost = PARK * periods[i] / 365 days / 10;
            emit log_named_uint("period", periods[i]);
            emit log_named_decimal_uint("  honest premium", honest, 18);
            emit log_named_decimal_uint("  lenders lose", honest - attacked, 18);
            emit log_named_uint("  discount (bps of honest)", _pct(honest - attacked, honest));
            emit log_named_decimal_uint("  attacker cost @10% APR", cost, 18);
            emit log_named_uint("  profit multiple", (honest - attacked) / (cost == 0 ? 1 : cost));
            if (attacked < honest) anyDiscount = true;
            vm.revertToState(snap);
        }
        assertFalse(anyDiscount, "profitable across the whole band");
    }

    function test_maxWindowStillProfitableForALargerLoan() public {
        irm.setAveragingPeriod(1 days);
        skip(30 days);
        uint256 loan = 5_000_000e18;

        uint256 snap = vm.snapshotState();
        uint256 honest = _borrowMaxTerm(loan);
        vm.revertToState(snap);

        _depositStable(attacker, PARK);
        skip(1 days);
        uint256 attacked = _borrowMaxTerm(loan);
        uint256 cost = PARK * 1 days / 365 days / 10;
        emit log_named_decimal_uint("honest premium on $5M/30d", honest, 18);
        emit log_named_decimal_uint("manipulated premium", attacked, 18);
        emit log_named_decimal_uint("lenders lose", honest - attacked, 18);
        emit log_named_uint("discount (bps of honest)", _pct(honest - attacked, honest));
        emit log_named_decimal_uint("attacker cost @10% APR for 1 day on $10M", cost, 18);
        emit log_named_uint("profit multiple", (honest - attacked) / (cost == 0 ? 1 : cost));
        assertEq(attacked, honest, "profitable even at the longest permitted window");
    }

    /// Round-3 addition: the same-block ("flash") variant the HEAD NatSpec says cannot suppress the
    /// price. Deposit and borrow in one block, no window elapsed: expected no discount.
    function test_flashDepositSameBlock_noDiscount() public {
        uint256 snap = vm.snapshotState();
        uint256 honest = _borrowMaxTerm(LOAN);
        vm.revertToState(snap);
        _depositStable(attacker, PARK);
        uint256 attacked = _borrowMaxTerm(LOAN);
        emit log_named_decimal_uint("honest premium", honest, 18);
        emit log_named_decimal_uint("same-block flash premium", attacked, 18);
        assertGe(attacked, honest, "a same-block deposit must not lower the premium");
    }
}
