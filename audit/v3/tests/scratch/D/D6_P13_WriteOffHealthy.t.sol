// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// WS-D P13 / I38: for lt*(1+b) > 1 there is a band where the market is healthy (liquidate
/// reverts Healthy()) while unrecoverableDebt() > 0, so GUARDIAN can write off against cUSD
/// holders with every dollar of tranche collateral still in the vault.
contract D6_P13_WriteOffHealthy is CapDeployer {
    using WadRayMath for uint256;

    FloatingMarket market;
    address senior;
    address junior;

    function setUp() public {
        _deployCap();
        (address m, address s, address j) = _createMarket("D6");
        market = FloatingMarket(m);
        senior = s;
        junior = j;
        _setMarketSlopes(m);
        market.setFixedCreditLimit(1_000_000e18);
        _fundTranche(senior, makeAddr("senior"), 500e18);
        _fundTranche(junior, makeAddr("junior"), 500e18);
    }

    function _enterBand() internal {
        // GOVERNOR: bonus to the setter maximum; GUARDIAN: lt to 0.95 (setter allows up to 1e27)
        irm.setLiquidationBonus(0.1e27);
        market.setLt(0.95e27);
        market.setLtv(0.85e27); // ltv + buffer(0.1) <= lt
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 850e18);
        // TC -> 900: band is debt in (TC/1.1, 0.95*TC] = (818.18, 855]; debt = 850
        _setPrice(address(collateral), 0.9e18);
    }

    /// I38 as stated in the plan. FAILS on current code.
    function test_FAIL_I38_unrecoverableImpliesUnhealthy() public {
        _enterBand();
        uint256 unrec = market.unrecoverableDebt();
        uint256 h = market.healthiness();
        emit log_named_decimal_uint("totalCapital     ", market.totalCapital(), 18);
        emit log_named_decimal_uint("totalDebt        ", market.totalDebt(), 18);
        emit log_named_decimal_uint("healthiness      ", h, 27);
        emit log_named_decimal_uint("unrecoverableDebt", unrec, 18);
        if (unrec > 0) assertLt(h, 1e27, "I38: unrecoverableDebt > 0 must imply healthiness < 1");
    }

    /// Ordered path: liquidate reverts, writeOff succeeds, tranches untouched, borrower forgiven.
    function test_writeOffSucceedsWhileLiquidateRevertsHealthy() public {
        _enterBand();
        assertGe(market.healthiness(), 1e27, "healthy");
        assertGt(market.unrecoverableDebt(), 0, "yet unrecoverable > 0");

        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        market.liquidate(defaultLiquidator, 100e18);

        uint256 seniorAssets = Tranche(senior).totalAssets();
        uint256 juniorAssets = Tranche(junior).totalAssets();
        uint256 debtBefore = market.totalDebt();
        uint256 supply = stablecoin.totalSupply();

        uint256 written = market.writeOff(); // GUARDIAN
        assertGt(written, 0);
        assertEq(stablecoin.badDebt(), written, "cUSD holders carry the loss");
        assertEq(Tranche(senior).totalAssets(), seniorAssets, "senior collateral untouched");
        assertEq(Tranche(junior).totalAssets(), juniorAssets, "junior collateral untouched");
        assertEq(market.totalDebt(), debtBefore - written, "borrower forgiven");
        assertLt(stablecoin.backing(), supply, "backing ratio dropped");
        emit log_named_decimal_uint("written off       ", written, 18);
        emit log_named_decimal_uint("backing / supply  ", stablecoin.backing().rayDiv(supply), 27);
        // and the market is now 'healthier' than before with nothing paid by anyone but cUSD holders
        assertGt(market.healthiness(), 1e27);
    }

    /// Same on a fixed market (writeOff(id) uses the same unrecoverableDebt bound).
    function test_fixedMarket_sameBand() public {
        (address m, address s,) = _createFixedMarket("D6F");
        FixedMarket fm = FixedMarket(m);
        fm.setUnderwriterRate(0);
        fm.setFixedCreditLimit(1_000_000e18);
        _fundTranche(s, makeAddr("s2"), 1_000e18);
        irm.setLiquidationBonus(0.1e27);
        fm.setLt(0.95e27);
        fm.setLtv(0.85e27);
        vm.prank(defaultBorrower);
        (uint256 id,) = fm.borrow(defaultBorrower, 850e18, 30 days);
        _setPrice(address(collateral), 0.9e18);
        assertGe(fm.healthiness(), 1e27);
        assertGt(fm.unrecoverableDebt(), 0);
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        fm.liquidate(id, defaultLiquidator, 1e18);
        uint256 written = fm.writeOff(id);
        assertGt(written, 0);
        assertEq(Tranche(s).totalAssets(), 1_000e18);
    }

    /// At deploy defaults (lt 0.8, b 0.02) the band is empty for every price: sweep.
    function test_bandEmptyAtDeployDefaults() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        for (uint256 p = 1e18; p >= 0.01e18; p -= 0.005e18) {
            _setPrice(address(collateral), p);
            if (market.unrecoverableDebt() > 0) assertLt(market.healthiness(), 1e27);
        }
    }

    /// The exact governance range: the band is non-empty iff lt * (1 + b) > 1e27.
    function testFuzz_bandExistsIff_ltTimesOnePlusBonusAboveOne(uint256 lt, uint256 b, uint256 ratio) public {
        lt = bound(lt, 0.2e27, 1e27); // setLt allows (buffer, 1e27]
        b = bound(b, 0, 0.1e27);
        uint256 lo = uint256(1e27).rayDiv(1e27 + b);
        vm.assume(lt > lo + 2e24);
        ratio = bound(ratio, lo + 1e24, lt - 1e24); // debt/TC inside (1/(1+b), lt]
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        irm.setLiquidationBonus(b);
        market.setLt(lt);
        // 1000 tokens; TC = 500/ratio -> price = 0.5/ratio, snapped to the feed's 8 decimals
        uint256 price = uint256(0.5e18).rayDiv(ratio);
        price -= price % 1e10;
        _setPrice(address(collateral), price);
        assertGe(market.healthiness(), 1e27, "healthy in band");
        assertGt(market.unrecoverableDebt(), 0, "unrecoverable in band");
    }
}
