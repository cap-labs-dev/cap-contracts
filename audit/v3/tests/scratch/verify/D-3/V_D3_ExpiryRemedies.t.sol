// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../../contracts/cap/market/FixedMarket.sol";
import { IBaseMarket } from "../../../../../../contracts/interfaces/IBaseMarket.sol";
import { IFixedMarket } from "../../../../../../contracts/interfaces/IFixedMarket.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// Adversarial verification of D-3. Three attacks on the finding:
///  (a) GUARDIAN setBuffer/setLt is an immediate, documented on-chain remedy for an expired loan;
///  (b) GOVERNOR setTermLimits + one KEEPER extendAdmin crystallises liquidatability at expiry+grace;
///  (c) numbers: at day 248 the liquidator does NOT "clear it" - maxLiquidatable is health-targeted,
///      so only ~58% clears and the residual decays geometrically over years.
contract V_D3_ExpiryRemedies is CapDeployer {
    FixedMarket fm;
    address senior;
    address junior;
    uint256 id;
    uint256 t0;

    function _setup(uint256 ltv_) internal {
        _deployCap(); // no liquidity slopes -> liquidity rate 0; underwriter rate 0.2/yr; lt 0.8; buffer 0.1
        (address m, address s, address j) = _createFixedMarket("V-D3");
        fm = FixedMarket(m);
        senior = s;
        junior = j;
        fm.setUnderwriterRate(0.2e27); // _createFixedMarket(string) does not apply capConfig.defaultUnderwriterRate
        fm.setLtv(ltv_);
        fm.setFixedCreditLimit(1_000_000e18);
        _fundTranche(s, makeAddr("s"), 1_000e18);
        vm.prank(defaultBorrower);
        (id,) = fm.borrow(defaultBorrower, type(uint256).max, 30 days);
        t0 = block.timestamp;
        _mintStable(defaultLiquidator, 10_000e18);
    }

    function _liquidateMax() internal returns (uint256 repaid, uint256 slashed) {
        uint256 max = fm.maxLiquidatable();
        vm.prank(defaultLiquidator);
        (repaid, slashed) = fm.liquidate(id, defaultLiquidator, max);
    }

    /// (a) Guardian lever. Expiry passes, market healthy, liquidate reverts Healthy. Guardian drops
    /// buffer to 0 and lt to 1 wei-ray: the whole loan becomes liquidatable in one shot at the
    /// inherent default cost D*(1+b). Parameters are restored in the same block.
    function test_guardianSetLt_clearsExpiredLoanAtExpiry() public {
        _setup(0.7e27);
        uint256 debt0 = fm.debt(id);
        vm.warp(fm.expiry(id) + 1);
        assertGe(fm.healthiness(), 1e27);
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        fm.liquidate(id, defaultLiquidator, 1e18);

        uint256 capBefore = fm.totalCapital();
        // GUARDIAN (address(this) holds the role in the harness)
        fm.setBuffer(0);
        fm.setLt(1);
        assertLt(fm.healthiness(), 1e27, "lt=1 wei forces unhealthy");
        emit log_named_decimal_uint("maxLiquidatable at lt=1wei   ", fm.maxLiquidatable(), 18);
        (uint256 repaid, uint256 slashed) = _liquidateMax();
        fm.setLt(0.8e27);
        fm.setBuffer(0.1e27);

        emit log_named_uint("days from borrow               ", (block.timestamp - t0) / 1 days);
        emit log_named_decimal_uint("debt before                    ", debt0, 18);
        emit log_named_decimal_uint("repaid in one shot             ", repaid, 18);
        emit log_named_decimal_uint("collateral slashed (USD)       ", slashed, 18);
        emit log_named_decimal_uint("debt remaining                 ", fm.debt(id), 18);
        emit log_named_decimal_uint("tranche capital after          ", fm.totalCapital(), 18);
        assertEq(fm.debt(id), 0, "fully cleared");
        assertApproxEqRel(slashed, debt0 * 102 / 100, 1e12, "slash = D*(1+b)");
        assertEq(capBefore - fm.totalCapital(), slashed);
        assertGe(fm.healthiness(), 1e27);
    }

    /// (a') Same lever at a modest lt (0.11): one shot clears ~96%, residual is then healthy again.
    function test_guardianSetLt_modestDrop_partialClear() public {
        _setup(0.7e27);
        vm.warp(fm.expiry(id) + 1);
        fm.setLt(0.11e27);
        (uint256 repaid,) = _liquidateMax();
        emit log_named_decimal_uint("repaid at lt=0.11              ", repaid, 18);
        emit log_named_decimal_uint("residual debt                  ", fm.debt(id), 18);
        emit log_named_decimal_uint("health at lt=0.11 after        ", fm.healthiness(), 27);
        fm.setLt(0.8e27);
        assertGt(fm.debt(id), 0);
    }

    /// (b) Governor+Keeper lever: raise maximumTermLimit, roll a long term once. Premium for the
    /// whole term is charged up front, so h<1 at expiry+grace (day 31) instead of day 248.
    function test_governorTermLimit_keeperCrystallisesAtGrace() public {
        _setup(0.7e27);
        fm.setTermLimits(365 days, 1 days); // GOVERNOR
        vm.warp(fm.expiry(id) + fm.grace() + 1);
        fm.extendAdmin(id, 365 days); // KEEPER
        emit log_named_uint("days from borrow               ", (block.timestamp - t0) / 1 days);
        emit log_named_decimal_uint("debt after one 365d roll       ", fm.debt(id), 18);
        emit log_named_decimal_uint("health                         ", fm.healthiness(), 27);
        assertLt(fm.healthiness(), 1e27);
        (uint256 repaid,) = _liquidateMax();
        emit log_named_decimal_uint("repaid (health-targeted)       ", repaid, 18);
        emit log_named_decimal_uint("residual debt                  ", fm.debt(id), 18);
    }

    /// (c) Keeper-only path, author's cadence. Correction: at day 248 liquidation is partial
    /// (maxLiquidatable targets health 1.25), the residual needs ~14 more rolls, and so on.
    function test_keeperPath_liquidationIsPartial_geometricTail() public {
        _setup(0.7e27);
        uint256 totalSlashed;
        uint256 totalRepaid;
        uint256 premiumToTranches;
        for (uint256 round; round < 4; ++round) {
            uint256 n;
            while (fm.healthiness() >= 1e27) {
                vm.warp(fm.expiry(id) + fm.grace() + 1);
                _setPrice(address(collateral), capConfig.collateralPrice); // keep the feed fresh over multi-year warps
                fm.extendAdmin(id, 30 days);
                ++n;
                if (n > 400) break;
            }
            uint256 debtBefore = fm.debt(id);
            (uint256 repaid, uint256 slashed) = _liquidateMax();
            totalSlashed += slashed;
            totalRepaid += repaid;
            emit log_named_uint("round                          ", round + 1);
            emit log_named_uint("  extendAdmin calls this round ", n);
            emit log_named_uint("  day of liquidation           ", (block.timestamp - t0) / 1 days);
            emit log_named_decimal_uint("  debt at liquidation          ", debtBefore, 18);
            emit log_named_decimal_uint("  repaid                       ", repaid, 18);
            emit log_named_decimal_uint("  residual debt                ", fm.debt(id), 18);
            emit log_named_decimal_uint("  health after                 ", fm.healthiness(), 27);
        }
        premiumToTranches = stablecoin.balanceOf(senior) + stablecoin.balanceOf(junior);
        emit log_named_decimal_uint("total slashed over 4 rounds    ", totalSlashed, 18);
        emit log_named_decimal_uint("total repaid over 4 rounds     ", totalRepaid, 18);
        emit log_named_decimal_uint("UW premium minted to tranches  ", premiumToTranches, 18);
        emit log_named_decimal_uint("tranche capital remaining      ", fm.totalCapital(), 18);
        emit log_named_decimal_uint("debt still open                ", fm.debt(id), 18);
        assertGt(fm.debt(id), 0, "still not cleared after 4 rounds");
    }

    /// Harness-default ltv 0.5 (h0 = 1.6): the keeper-only timeline at deploy rates.
    function test_keeperPath_defaultLtv05_timeline() public {
        _setup(0.5e27);
        uint256 n;
        while (fm.healthiness() >= 1e27) {
            vm.warp(fm.expiry(id) + fm.grace() + 1);
            fm.extendAdmin(id, 30 days);
            ++n;
            if (n > 400) break;
        }
        emit log_named_uint("extendAdmin calls              ", n);
        emit log_named_uint("days from borrow to h < 1      ", (block.timestamp - t0) / 1 days);
        emit log_named_decimal_uint("debt when liquidatable         ", fm.debt(id), 18);
    }

    /// Borrower-side: a performing-but-late borrower cannot be forced out by underwriters or the
    /// market owner; keeping the loan open costs exactly the contracted rate via extendAdmin.
    /// Repaying part each cycle keeps it healthy forever. (Illiquidity for underwriters, not loss.)
    function test_borrowerCanRollForeverByPayingTheRate() public {
        _setup(0.7e27);
        _mintStable(defaultBorrower, 1_000e18);
        for (uint256 i; i < 12; ++i) {
            vm.warp(fm.expiry(id) + fm.grace() + 1);
            _setPrice(address(collateral), capConfig.collateralPrice);
            uint256 before = fm.debt(id);
            fm.extendAdmin(id, 30 days);
            uint256 premium = fm.debt(id) - before;
            vm.prank(defaultBorrower);
            fm.repay(id, premium); // pay just the premium
            assertGe(fm.healthiness(), 1e27);
        }
        emit log_named_uint("days open                      ", (block.timestamp - t0) / 1 days);
        emit log_named_decimal_uint("debt (unchanged principal)     ", fm.debt(id), 18);
        emit log_named_decimal_uint("senior unlockedSupply          ", Tranche(senior).unlockedSupply(), 18);
        assertLe(Tranche(senior).unlockedSupply(), 1, "underwriter fully locked while it rolls (1 wei rounding)");
    }
}
