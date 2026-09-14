// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// WS-D P9: once unrecoverableDebt > 0, permissionless chargePremium() keeps minting
/// credit-backed cUSD (underwriter premium to tranches with residual capital and staked supply,
/// liquidity premium and ineligible weight to the stablecoin pot). The eventual write-off grows
/// by exactly the premium minted during the GUARDIAN's delay.
contract D7_P9_InsolventPremium is CapDeployer {
    using WadRayMath for uint256;

    FloatingMarket market;
    address senior;
    address junior;

    function setUp() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = true;
        _deployCapWithConfig(cfg);
        (address m, address s, address j) = _createMarket("D7");
        market = FloatingMarket(m);
        senior = s;
        junior = j;
        irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        market.setUnderwriterRate(0.2e27);
        market.setFixedCreditLimit(1_000_000e18);
        _fundTranche(senior, makeAddr("senior"), 500e18);
        _fundTranche(junior, makeAddr("junior"), 500e18);
        _depositStable(makeAddr("lp"), 500e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        _setPrice(address(collateral), 0.1e18); // TC 100; unrecoverable = 500 - 98.04
        market.chargePremium(); // checkpoint at T
        assertGt(market.unrecoverableDebt(), 0);
    }

    /// FAILS on current code: the amount written off depends on how long the guardian waits.
    function test_FAIL_writeOffIndependentOfGuardianDelay() public {
        uint256 unrec0 = market.unrecoverableDebt();
        uint256 snap = vm.snapshotState();
        uint256 written0 = market.writeOff();
        vm.revertToState(snap);

        skip(1 days);
        vm.prank(makeAddr("anyone"));
        market.chargePremium();
        uint256 written1 = market.writeOff();
        emit log_named_decimal_uint("unrecoverable at T        ", unrec0, 18);
        emit log_named_decimal_uint("written off at T          ", written0, 18);
        emit log_named_decimal_uint("written off at T+1d       ", written1, 18);
        emit log_named_decimal_uint("extra bad debt per day    ", written1 - written0, 18);
        assertEq(written1, written0, "bad debt recognised must not grow with guardian delay");
    }

    /// Who receives the unbacked cUSD: tranches with residual capital and staked supply (here
    /// both, weight 0.95/0.05) take the underwriter premium; the liquidity premium goes to the
    /// stablecoin vesting pot (i.e. opted-in cUSD holders).
    function test_recipientsOfUnbackedPremium_residualCapital() public {
        uint256 s0 = stablecoin.balanceOf(senior);
        uint256 j0 = stablecoin.balanceOf(junior);
        uint256 pot0 = stablecoin.balanceOf(address(stablecoin));
        uint256 cbs0 = stablecoin.creditBackedSupply();
        uint256 debt0 = market.totalDebt();
        skip(1 days);
        (uint256 liq, uint256 uw) = market.premium();
        vm.prank(makeAddr("anyone"));
        market.chargePremium();
        emit log_named_decimal_uint("liquidity premium / day   ", liq, 18);
        emit log_named_decimal_uint("underwriter premium / day ", uw, 18);
        emit log_named_decimal_uint("  -> senior tranche       ", stablecoin.balanceOf(senior) - s0, 18);
        emit log_named_decimal_uint("  -> junior tranche       ", stablecoin.balanceOf(junior) - j0, 18);
        emit log_named_decimal_uint("  -> stablecoin pot       ", stablecoin.balanceOf(address(stablecoin)) - pot0, 18);
        assertEq(stablecoin.creditBackedSupply() - cbs0, liq + uw, "all of it is credit-backed supply");
        assertEq(market.totalDebt() - debt0, liq + uw, "all of it is debt on an insolvent market");
        assertGt(stablecoin.balanceOf(senior) - s0, 0, "senior stakers paid with unbacked cUSD");
    }

    /// After a liquidation drains every tranche (totalCapital == 0), nothing is eligible, so
    /// the whole premium is minted to the stablecoin's own pot: cUSD holders are paid in cUSD
    /// that the write-off then charges back to all cUSD holders.
    function test_recipientsOfUnbackedPremium_drained() public {
        uint256 max = market.maxLiquidatable();
        _mintStable(defaultLiquidator, max);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, max);
        assertEq(market.totalCapital(), 0, "drained");
        assertGt(market.unrecoverableDebt(), 0);
        uint256 pot0 = stablecoin.balanceOf(address(stablecoin));
        uint256 s0 = stablecoin.balanceOf(senior);
        skip(1 days);
        vm.prank(makeAddr("anyone"));
        market.chargePremium();
        assertEq(stablecoin.balanceOf(senior), s0, "empty tranche gets nothing");
        uint256 potGain = stablecoin.balanceOf(address(stablecoin)) - pot0;
        assertGt(potGain, 0);
        emit log_named_decimal_uint("minted into stablecoin pot on a fully drained market, per day", potGain, 18);
        uint256 written = market.writeOff();
        emit log_named_decimal_uint("written off (incl. that premium)", written, 18);
        assertGt(written, market.totalDebt() + 0); // debt remaining after write-off = recoverable = 0
    }

    /// Fixed market: extendAdmin after grace charges arrears premium on the whole loan including
    /// the unrecoverable part.
    function test_fixed_extendAdminMintsOnInsolventLoan() public {
        (address m, address s,) = _createFixedMarket("D7F");
        FixedMarket fm = FixedMarket(m);
        fm.setUnderwriterRate(0.2e27);
        fm.setFixedCreditLimit(1_000_000e18);
        _fundTranche(s, makeAddr("fs"), 1_000e18);
        _setPrice(address(collateral), 1e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = fm.borrow(defaultBorrower, 400e18, 30 days);
        _setPrice(address(collateral), 0.1e18);
        uint256 unrec0 = fm.unrecoverableDebt();
        assertGt(unrec0, 0);
        skip(31 days + 1);
        fm.extendAdmin(id, 30 days); // KEEPER
        uint256 unrec1 = fm.unrecoverableDebt();
        emit log_named_decimal_uint("unrecoverable before extendAdmin", unrec0, 18);
        emit log_named_decimal_uint("unrecoverable after  extendAdmin", unrec1, 18);
        assertGt(unrec1, unrec0);
    }
}
