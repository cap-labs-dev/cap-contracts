// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../../contracts/interfaces/IBaseMarket.sol";
import { WadRayMath } from "../../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// Independent verification of D-2: the healthy-but-unrecoverable band and what a write-off
/// inside it does to cUSD holders relative to the alternatives.
contract V_D2_WriteOffBand is CapDeployer {
    using WadRayMath for uint256;

    FloatingMarket market;
    address senior;
    address junior;

    function setUp() public {
        _deployCap();
        (address m, address s, address j) = _createMarket("VD2");
        market = FloatingMarket(m);
        senior = s;
        junior = j;
        _setMarketSlopes(m);
        market.setFixedCreditLimit(1_000_000e18);
        _fundTranche(senior, makeAddr("senior"), 500e18);
        _fundTranche(junior, makeAddr("junior"), 500e18);
    }

    /// Enter the band with ONLY a GUARDIAN action: lt = 1e27 (the setter maximum) at the deploy
    /// bonus of 2%. Band is debt/TC in (1/1.02, 1] = (0.9804, 1]. Borrow 500 at $1 (ltv 0.5),
    /// reprice to $0.505: TC = 505, D = 500, ratio 0.990.
    function _enterBandGuardianOnly() internal {
        market.setLt(1e27); // GUARDIAN
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        _setPrice(address(collateral), 0.505e18);
    }

    function test_guardianOnly_bandExistsAtDeployBonus() public {
        assertEq(irm.liquidationBonus(), 0.02e27, "deploy bonus untouched, GOVERNOR not involved");
        _enterBandGuardianOnly();

        uint256 tc = market.totalCapital();
        uint256 d = market.totalDebt();
        uint256 h = market.healthiness();
        uint256 u = market.unrecoverableDebt();
        emit log_named_decimal_uint("TC", tc, 18);
        emit log_named_decimal_uint("D ", d, 18);
        emit log_named_decimal_uint("h ", h, 27);
        emit log_named_decimal_uint("U ", u, 18);

        assertEq(tc, 505e18);
        assertEq(d, 500e18);
        assertGe(h, 1e27, "healthy");
        assertGt(u, 0, "unrecoverable > 0");
        // re-derived closed form: U = D - TC/(1+b)
        assertApproxEqAbs(u, d - tc.rayDiv(1.02e27), 2, "U = D - TC/(1+b)");
        // band-wide bound: U <= TC * (lt - 1/(1+b)) = 505 * (1 - 0.98039) = 9.90
        assertLe(u, tc.rayMul(1e27 - uint256(1e27).rayDiv(1.02e27)) + 1, "U bounded by TC*(lt-1/(1+b))");

        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        market.liquidate(defaultLiquidator, 100e18);

        uint256 written = market.writeOff(); // GUARDIAN, second action
        assertEq(written, u, "full U written off while healthy");
        assertEq(stablecoin.badDebt(), u);
        assertEq(Tranche(senior).totalAssets(), 500e18, "senior untouched");
        assertEq(Tranche(junior).totalAssets(), 500e18, "junior untouched");
    }

    /// Neither setter checks the product, in either order.
    function test_settersIndependent_bothOrders() public {
        market.setLt(1e27);
        irm.setLiquidationBonus(0.1e27); // no revert with lt already at 1
        assertEq(irm.liquidationBonus(), 0.1e27);
        market.setLt(0.95e27); // no revert with bonus already at 0.1
        assertEq(market.lt(), 0.95e27);
        assertGt(market.lt().rayMul(1e27 + irm.liquidationBonus()), 1e27, "product > 1 accepted");
    }

    /// Is the in-band write-off harmful? Compare against the two real alternatives from the same
    /// state: (a) borrower repays in full, (b) price keeps falling and the market is liquidated to
    /// exhaustion then written off.
    function test_inBandWriteOff_isPureOptionTransferToBorrower() public {
        _enterBandGuardianOnly();
        uint256 u = market.unrecoverableDebt();
        uint256 d = market.totalDebt();
        uint256 snap = vm.snapshotState();

        // (a1) write off now, then borrower repays everything left
        market.writeOff();
        _mintStable(defaultBorrower, d);
        vm.prank(defaultBorrower);
        market.repay(type(uint256).max);
        assertEq(market.totalDebt(), 0);
        uint256 badDebt_writeOffThenRepay = stablecoin.badDebt();
        uint256 borrowerPaid_a1 = d - u;
        emit log_named_decimal_uint("(a1) write-off then repay: badDebt", badDebt_writeOffThenRepay, 18);

        vm.revertToState(snap);
        // (a2) do nothing, borrower repays everything
        _mintStable(defaultBorrower, d);
        vm.prank(defaultBorrower);
        market.repay(type(uint256).max);
        assertEq(market.totalDebt(), 0);
        uint256 badDebt_repayOnly = stablecoin.badDebt();
        emit log_named_decimal_uint("(a2) no write-off, repay:  badDebt", badDebt_repayOnly, 18);

        assertEq(badDebt_repayOnly, 0, "no loss if the guardian waits and the borrower repays");
        assertEq(badDebt_writeOffThenRepay, u, "loss of exactly U crystallised by the write-off");
        assertEq(borrowerPaid_a1, d - u, "borrower paid U less");

        vm.revertToState(snap);
        // (b1) write off now, then price falls to $0.30, liquidate to exhaustion, write off rest
        market.writeOff();
        _setPrice(address(collateral), 0.3e18);
        _mintStable(defaultLiquidator, 1_000e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, type(uint256).max);
        assertEq(market.totalCapital(), 0, "collateral exhausted");
        market.writeOff();
        uint256 badDebt_b1 = stablecoin.badDebt();
        emit log_named_decimal_uint("(b1) write-off, crash, liq, write-off: badDebt", badDebt_b1, 18);

        vm.revertToState(snap);
        // (b2) do nothing now, price falls to $0.30, liquidate to exhaustion, write off
        _setPrice(address(collateral), 0.3e18);
        _mintStable(defaultLiquidator, 1_000e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, type(uint256).max);
        assertEq(market.totalCapital(), 0, "collateral exhausted");
        market.writeOff();
        uint256 badDebt_b2 = stablecoin.badDebt();
        emit log_named_decimal_uint("(b2) crash, liq, write-off:            badDebt", badDebt_b2, 18);

        assertApproxEqAbs(badDebt_b1, badDebt_b2, 2, "in the crash branch the early write-off changes nothing");
        // => early write-off is never better for cUSD holders and strictly worse if the borrower repays
    }

    /// Converse of I38: with lt*(1+b) <= 1e27 the band is empty for every debt/TC ratio.
    function testFuzz_I38_holdsWhenProductAtMostOne(uint256 lt, uint256 b, uint256 ratio) public {
        lt = bound(lt, 0.2e27, 1e27);
        b = bound(b, 0, 0.1e27);
        vm.assume(lt.rayMul(1e27 + b) <= 1e27);
        ratio = bound(ratio, 0.05e27, 2e27); // debt/TC anywhere across healthy and deeply insolvent
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        irm.setLiquidationBonus(b);
        market.setLt(lt);
        uint256 price = uint256(0.5e18).rayDiv(ratio);
        price -= price % 1e10;
        _setPrice(address(collateral), price);
        if (market.unrecoverableDebt() > 0) assertLt(market.healthiness(), 1e27, "I38 holds when lt(1+b)<=1");
    }

    /// Fixed market, GUARDIAN-only configuration: same band, same result.
    function test_fixedMarket_guardianOnly() public {
        (address m, address s,) = _createFixedMarket("VD2F");
        FixedMarket fm = FixedMarket(m);
        fm.setUnderwriterRate(0);
        fm.setFixedCreditLimit(1_000_000e18);
        _fundTranche(s, makeAddr("s2"), 1_000e18);
        fm.setLt(1e27); // GUARDIAN only; bonus stays 0.02
        vm.prank(defaultBorrower);
        (uint256 id,) = fm.borrow(defaultBorrower, 500e18, 30 days);
        _setPrice(address(collateral), 0.505e18); // TC 505, D 500 (rate 0, no premium) -> ratio 0.990
        emit log_named_decimal_uint("fixed h", fm.healthiness(), 27);
        emit log_named_decimal_uint("fixed U", fm.unrecoverableDebt(), 18);
        assertGe(fm.healthiness(), 1e27);
        assertGt(fm.unrecoverableDebt(), 0);
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        fm.liquidate(id, defaultLiquidator, 1e18);
        uint256 written = fm.writeOff(id);
        assertGt(written, 0);
        assertEq(Tranche(s).totalAssets(), 1_000e18, "tranche untouched");
    }
}
