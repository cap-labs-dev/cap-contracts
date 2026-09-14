// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

contract AuditSecurityTest is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function test_multiplierScalesFloatingLiquidityGrowth() public {
        irm.setLiquiditySlopes(IInterestRateModel.Slopes({ base: 0.1e27, slope0: 0, slope1: 0, kink: 0.8e27 }));
        (address a, address ta,) = _createMarket("one");
        (address b, address tb,) = _createMarket("two");
        FloatingMarket(b).setMarketMultiplier(2e27);
        _fundTranche(ta, makeAddr("lp1"), 10_000e18);
        _fundTranche(tb, makeAddr("lp2"), 10_000e18);
        vm.startPrank(defaultBorrower);
        FloatingMarket(a).borrow(defaultBorrower, 1000e18);
        FloatingMarket(b).borrow(defaultBorrower, 1000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);
        uint256 debtA = FloatingMarket(a).totalDebt();
        uint256 debtB = FloatingMarket(b).totalDebt();
        assertGt(debtA, 1000e18);
        // 2x squares the growth factor: debtB / 1000 = (debtA / 1000)^2
        assertApproxEqRel(debtB, debtA * debtA / 1000e18, 1e15);
    }

    function test_realisingInterestDoesNotChangeWhatIsOwed() public {
        irm.setLiquiditySlopes(IInterestRateModel.Slopes({ base: 0.1e27, slope0: 0, slope1: 0, kink: 0.8e27 }));
        (address quiet, address tq,) = _createMarket("quiet");
        (address busy, address tb,) = _createMarket("busy");
        FloatingMarket(quiet).setMarketMultiplier(2e27);
        FloatingMarket(busy).setMarketMultiplier(2e27);
        _fundTranche(tq, makeAddr("lpq"), 10_000e18);
        _fundTranche(tb, makeAddr("lpb"), 10_000e18);
        vm.startPrank(defaultBorrower);
        FloatingMarket(quiet).borrow(defaultBorrower, 1000e18);
        FloatingMarket(busy).borrow(defaultBorrower, 1000e18);
        vm.stopPrank();

        for (uint256 i; i < 2; ++i) {
            vm.warp(block.timestamp + 182 days);
            FloatingMarket(busy).chargePremium();
        }
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(FloatingMarket(quiet).totalDebt(), FloatingMarket(busy).totalDebt(), 1e12);
    }

    /// @dev Yearn-style report lag: slash writes the tranche down immediately, and this vault
    /// keeps the previous mark until allocate, deallocate, or report. First exit against idle
    /// cash is priced off that book. That is the intended share-price model, not a live NAV.
    function test_underwriterRedeemsBeforeSlashIsMarked() public {
        (address m, address t,) = _createMarket("market");
        Underwriter uw = _deployUnderwriter();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _fundUnderwriter(address(uw), alice, 1000e18);
        _fundUnderwriter(address(uw), bob, 1000e18);
        _admitDepositor(t, address(uw));
        uw.addTranche(t);
        uw.allocate(t, 1000e18);
        // This is the state transition caused by the market's liquidation waterfall.
        vm.prank(m);
        Tranche(t).slash(500e18, makeAddr("liquidator"));
        uint256 trueAssets = vault.balanceOf(address(uw), address(collateral))
            + Tranche(t).convertToAssets(Tranche(t).balanceOf(address(uw)));
        assertApproxEqAbs(trueAssets, 1500e18, 2000);
        assertApproxEqAbs(uw.totalAssets(), 2000e18, 2000);
        uint256 aliceShares = uw.balanceOf(alice);
        uint256 fairAssets = aliceShares * trueAssets / uw.totalSupply();
        vm.prank(alice);
        uint256 paid = uw.instantRedeem(aliceShares, alice, alice);
        assertGt(paid, fairAssets + 249e18);
        uw.report(t);
        assertLt(uw.convertToAssets(uw.balanceOf(bob)), 501e18);
    }
}
