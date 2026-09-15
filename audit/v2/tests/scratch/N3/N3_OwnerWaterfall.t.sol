// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { console } from "forge-std/console.sol";

/// N7: market OWNER strips the junior tranche out of the waterfall after the borrow.
contract N3_OwnerWaterfall is CapDeployer {
    MarketBundle b;
    address senior = makeAddr("seniorLP");
    address junior = makeAddr("juniorLP");

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M"); // ltv 0.5, lt 0.8, buffer 0.1, price $1
        _fundTranche(b.tranche0Addr, senior, 1_000e18);
        _fundTranche(b.tranche1Addr, junior, 600e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max); // 0.5 * 1600 = 800
    }

    function test_N7_ownerRemovesFundedJuniorTrancheAfterBorrow() public {
        assertEq(b.market.totalDebt(), 800e18);
        assertEq(b.market.healthiness(), 1.6e27);
        uint256 juniorUnlockedBefore = b.tranche1.unlockedSupply();
        console.log("junior unlocked before strip:", juniorUnlockedBefore);

        IBaseMarket.Tranche[] memory only = new IBaseMarket.Tranche[](1);
        only[0] = IBaseMarket.Tranche({ tranche: b.tranche0Addr, weight: 1e27 });
        vm.prank(defaultMarketOwner);
        b.market.setTranches(only); // passes: 1000 * 0.8 / 800 == 1.0 exactly

        assertEq(b.market.healthiness(), 1e27, "coverage stripped to the liquidation line");
        assertEq(b.market.totalCapital(), 1_000e18, "junior capital no longer counted");
        uint256 juniorUnlocked = b.tranche1.unlockedSupply();
        console.log("junior unlocked after strip:", juniorUnlocked);
        console.log("lockedValue(junior):", b.market.lockedValue(b.tranche1Addr));
        assertGt(juniorUnlocked, juniorUnlockedBefore);

        // junior LP walks out with most of its capital while the loan is outstanding
        vm.prank(junior);
        uint256 out = b.tranche1.redeem(juniorUnlocked, junior, junior);
        console.log("junior redeemed (wei):", out);
        assertGt(out, 450e18);

        // a 1 bp price move now makes the market liquidatable and only the senior tranche is
        // in the slash loop
        _setPrice(address(collateral), 0.9999e18);
        assertLt(b.market.healthiness(), 1e27);
        IBaseMarket.Tranche[] memory t = b.market.tranches();
        assertEq(t.length, 1);
        assertEq(t[0].tranche, b.tranche0Addr);
    }

    function test_N7_registryAllowsOwnerEqualsBorrower() public {
        address both = makeAddr("ownerBorrower");
        _assignOperator(both);
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e27;
        w[1] = 0.5e27;
        (address m,) = registry.createFloatingMarket(_uniformAssets(2), w, "Self", both, both);
        assertEq(registry.marketOwnerRole(m), registry.operatorRole(both));
    }

    function test_N7_seniorLpCannotVetoAndAdminIsNotInvolved() public {
        IBaseMarket.Tranche[] memory only = new IBaseMarket.Tranche[](1);
        only[0] = IBaseMarket.Tranche({ tranche: b.tranche0Addr, weight: 1e27 });
        vm.prank(senior);
        vm.expectRevert();
        b.market.setTranches(only);
        // round-1 baseline: this selector was ADMIN
        assertEq(
            accessManager.getTargetFunctionRole(b.marketAddr, IBaseMarket.setTranches.selector),
            registry.operatorRole(defaultMarketOwner)
        );
    }
}
