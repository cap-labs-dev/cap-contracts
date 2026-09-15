// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IBaseMarket } from "../../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapRoles } from "../../../../../../contracts/utils/CapRoles.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { console } from "forge-std/console.sol";

/// Adversarial verification of N3-2 (R2-MED-OWNER-SETTRANCHES).
/// Market: ltv 0.5, lt 0.8, buffer 0.1, bonus 2%, price $1. senior 1000 / junior 600 / debt 800.
contract Verify_OwnerSetTranches is CapDeployer {
    MarketBundle b;
    address senior = makeAddr("seniorLP");
    address junior = makeAddr("juniorLP");

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M");
        _fundTranche(b.tranche0Addr, senior, 1_000e18);
        _fundTranche(b.tranche1Addr, junior, 600e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max); // 800
        assertEq(b.market.totalDebt(), 800e18);
    }

    function _strip() internal {
        IBaseMarket.Tranche[] memory only = new IBaseMarket.Tranche[](1);
        only[0] = IBaseMarket.Tranche({ tranche: b.tranche0Addr, weight: 1e27 });
        vm.prank(defaultMarketOwner);
        b.market.setTranches(only);
    }

    function _liquidateAll() internal returns (uint256 repaid, uint256 slashed) {
        _mintStable(defaultLiquidator, 2_000e18);
        vm.prank(defaultLiquidator);
        (repaid, slashed) = b.market.liquidate(defaultLiquidator, type(uint256).max);
    }

    /// Angle (c)/(a): the PoC's owner is NOT the borrower (defaultMarketOwner = this, borrower = makeAddr).
    function test_A0_pocOwnerIsNotBorrower() public view {
        assertTrue(defaultMarketOwner != defaultBorrower);
    }

    /// Baseline: at a 30% collateral drop the untouched market is still healthy and nobody is slashed.
    function test_A1_baseline_30pctDrop_nobodySlashed() public {
        _setPrice(address(collateral), 0.7e18);
        assertGe(b.market.healthiness(), 1e27); // 1600*0.7*0.8/800 = 1.12
        vm.prank(defaultLiquidator);
        vm.expectRevert(); // Healthy()
        b.market.liquidate(defaultLiquidator, type(uint256).max);
    }

    /// Stripped: same 30% drop wipes the senior entirely; the junior is untouched and, once the residual
    /// debt is written off, fully redeemable.
    function test_A2_strip_30pctDrop_seniorWipedJuniorWhole() public {
        _strip();
        uint256 seniorUnlockedAfterStrip = b.tranche0.unlockedSupply();
        console.log("senior unlockedSupply after strip:", seniorUnlockedAfterStrip);
        assertEq(seniorUnlockedAfterStrip, 0, "senior fully locked after strip");

        _setPrice(address(collateral), 0.7e18);
        assertLt(b.market.healthiness(), 1e27);
        uint256 jBefore = b.tranche1.totalAssets();
        (uint256 repaid, uint256 slashed) = _liquidateAll();
        console.log("repaid:", repaid, "slashed USD:", slashed);
        console.log("senior assets after liquidation:", b.tranche0.totalAssets());
        console.log("junior assets after liquidation:", b.tranche1.totalAssets());
        assertEq(b.tranche1.totalAssets(), jBefore, "junior never slashed");
        assertLt(b.tranche0.totalAssets(), 1e18, "senior wiped (dead-share dust only)");

        // residual debt has zero recoverable collateral -> guardian writes it off -> junior fully unlocks
        uint256 residual = b.market.totalDebt();
        console.log("residual debt:", residual);
        assertGt(residual, 0);
        b.market.writeOff(); // test contract holds GUARDIAN
        assertEq(b.market.totalDebt(), 0);
        uint256 jUnlocked = b.tranche1.unlockedSupply();
        console.log("junior unlocked after writeOff:", jUnlocked, "of", b.tranche1.totalSupply());
        assertEq(jUnlocked, b.tranche1.totalSupply());
        uint256 jShares = b.tranche1.balanceOf(junior);
        vm.prank(junior);
        uint256 out = b.tranche1.redeem(jShares, junior, junior);
        console.log("junior redeemed tokens:", out);
        assertGt(out, 599e18); // 600 minus dead-share seed
    }

    /// Angle (a): what the owner could reach at 3c45dca with setLtv alone (weights do not touch the waterfall).
    /// ltv -> lt-buffer = 0.7, borrower draws max, price drops 30%: junior is STILL slashed first.
    function test_A3_v1Reach_setLtvOnly_juniorStillFirstLoss() public {
        vm.prank(defaultMarketOwner);
        b.market.setLtv(0.7e27);
        vm.prank(defaultMarketOwner);
        vm.expectRevert();
        b.market.setLtv(0.7e27 + 1);
        b.market.setFixedCreditLimit(type(uint256).max);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max);
        uint256 debt = b.market.totalDebt();
        console.log("debt at ltv 0.7:", debt); // 1120
        assertEq(debt, 1_120e18);
        console.log("healthiness at ltv 0.7:", b.market.healthiness()); // 1.142857e27

        _setPrice(address(collateral), 0.85e18);
        assertLt(b.market.healthiness(), 1e27); // 1600*0.85*0.8/1120 = 0.971
        (uint256 repaid, uint256 slashed) = _liquidateAll();
        console.log("repaid:", repaid, "slashed USD:", slashed);
        console.log("senior assets:", b.tranche0.totalAssets(), "junior assets:", b.tranche1.totalAssets());
        assertLt(b.tranche1.totalAssets(), 1e18, "junior wiped first");
        assertGt(b.tranche0.totalAssets(), 0);
        // senior loss on a full slash at par would be 1120*1.02 - 600 = 542.4 (54%), not 80%+
    }

    /// Angle (b): reorder is also accepted. Health is unchanged at 1.6 so the "health >= 1.0" gate is not
    /// what makes this safe or unsafe; the senior LP silently becomes first-loss and fully locked.
    function test_B_reorder_passesHealth_seniorBecomesFirstLossAndLocked() public {
        uint256 seniorUnlockedBefore = b.tranche0.unlockedSupply();
        console.log("senior unlocked before reorder:", seniorUnlockedBefore); // ~457
        assertGt(seniorUnlockedBefore, 0);
        IBaseMarket.Tranche[] memory swapped = new IBaseMarket.Tranche[](2);
        swapped[0] = IBaseMarket.Tranche({ tranche: b.tranche1Addr, weight: 0.95e27 });
        swapped[1] = IBaseMarket.Tranche({ tranche: b.tranche0Addr, weight: 0.05e27 });
        vm.prank(defaultMarketOwner);
        b.market.setTranches(swapped);
        assertEq(b.market.healthiness(), 1.6e27, "health untouched by reorder");
        assertEq(b.tranche0.unlockedSupply(), 0, "former senior now fully locked");
        console.log("junior unlocked after reorder:", b.tranche1.unlockedSupply()); // junior now senior: 542 unlocked

        _setPrice(address(collateral), 0.6e18); // capital 960, health 0.96
        assertLt(b.market.healthiness(), 1e27);
        uint256 s0 = b.tranche0.totalAssets();
        uint256 j0 = b.tranche1.totalAssets();
        _liquidateAll();
        console.log("former-senior slashed tokens:", s0 - b.tranche0.totalAssets());
        console.log("former-junior slashed tokens:", j0 - b.tranche1.totalAssets());
        assertLt(b.tranche0.totalAssets(), s0, "former senior slashed");
        assertEq(b.tranche1.totalAssets(), j0, "former junior untouched");
    }

    /// Angle (d): the removed tranche's residual lock is a side quirk, not the harm. Even if the removed
    /// tranche were treated as fully locked, it is outside the slash loop, so the senior's exposure is
    /// identical. Show: after strip the senior alone backs the whole debt (recoverable capital == senior only).
    function test_D_removedTrancheOutsideSlashLoopRegardlessOfLock() public {
        _strip();
        assertEq(b.market.totalCapital(), 1_000e18);
        assertEq(b.market.recoverableDebt(), uint256(1_000e18) * 1e27 / 1.02e27);
        // lockedValue for the unlisted junior uses the most-senior formula: 800/0.7 - 1000 = 142.86
        assertEq(b.market.lockedValue(b.tranche1Addr), 142857142857142857143);
    }

    /// Angle (f): no other role can undo a strip. Only the owner role (and the Registry, which has no
    /// entry point for it) may call setTranches; GUARDIAN/GOVERNOR/ADMIN cannot.
    function test_F_noProtocolRoleCanUndo() public {
        _strip();
        address guardian = makeAddr("guardian");
        address governor = makeAddr("governor");
        accessManager.grantRole(CapRoles.GUARDIAN, guardian, 0);
        accessManager.grantRole(CapRoles.GOVERNOR, governor, 0);
        (bool g1,) = accessManager.canCall(guardian, b.marketAddr, IBaseMarket.setTranches.selector);
        (bool g2,) = accessManager.canCall(governor, b.marketAddr, IBaseMarket.setTranches.selector);
        assertFalse(g1);
        assertFalse(g2);
        (bool reg,) = accessManager.canCall(address(registry), b.marketAddr, IBaseMarket.setTranches.selector);
        assertTrue(reg, "registry holds owner role but exposes only createTranche (append)");
    }
}
