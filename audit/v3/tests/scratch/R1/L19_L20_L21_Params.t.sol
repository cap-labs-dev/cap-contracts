// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 cheap checks for the three model-owned round-1 Lows that had no PoC:
///  L-19 `_setLiquidationBonus` (InterestRateModel.sol:180-184) permits 0.
///  L-20 `maxLiquidatable` (BaseMarket.sol:245-255) clears (TH-1)/(TH-(1+b)*lt) of debt at health 1.
///  L-21 `setUnderwriterRate` (BaseMarket.sol:130-134 -> IRM :124-131) is owner-set, floor 0, no notice.
/// Each asserts the desired property so a FAIL reproduces the finding.
contract R1_L19_L20_L21_Params is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function test_L19_zeroLiquidationBonusPermitted() public {
        irm.setLiquidationBonus(0);
        emit log_named_uint("liquidationBonus after set(0)", irm.liquidationBonus());
        assertGt(irm.liquidationBonus(), 0, "a zero bonus is indistinguishable from an offline liquidator");
    }

    function test_L20_firstLiquidationCliff() public {
        MarketBundle memory b = _createReadyMarket("M");
        b.market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(b.tranche0Addr, makeAddr("s"), 950e18);
        _fundTranche(b.tranche1Addr, makeAddr("j"), 50e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);
        _setPrice(address(collateral), 0.624e18); // health 0.9984
        uint256 debt = b.market.totalDebt();
        uint256 clip = b.market.maxLiquidatable();
        emit log_named_uint("healthiness (ray)", b.market.healthiness());
        emit log_named_uint("first clip, bps of debt", clip * 10_000 / debt);
        emit log_named_uint("junior capital before", b.tranche1.totalCapital());
        _depositStable(defaultLiquidator, clip);
        vm.prank(defaultLiquidator);
        b.market.liquidate(defaultLiquidator, type(uint256).max);
        emit log_named_uint("junior capital after", b.tranche1.totalCapital());
        emit log_named_string("junior killed", b.tranche1.killed() ? "yes" : "no");
        assertLt(clip * 10_000 / debt, 5_000, "first liquidation at health ~1 clears more than half the debt");
    }

    function test_L21_ownerZeroesUnderwriterRateWhileCapitalLocked() public {
        MarketBundle memory b = _createReadyMarket("M");
        address uw = makeAddr("uw");
        _fundTranche(b.tranche0Addr, uw, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);
        uint256 locked = b.tranche0.totalSupply() - b.tranche0.unlockedSupply();
        emit log_named_uint("underwriter shares locked by the draw", locked);
        assertGt(locked, 0);
        b.market.setUnderwriterRate(0); // market owner; takes effect immediately, floor 0
        assertGt(
            irm.underwriterRate(b.marketAddr), 0, "owner zeroed the underwriters' compensation with no floor or notice"
        );
    }
}
