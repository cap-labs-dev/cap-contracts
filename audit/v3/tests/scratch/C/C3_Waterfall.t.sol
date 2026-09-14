// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { IRegistry } from "../../../../../contracts/interfaces/IRegistry.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { console } from "forge-std/console.sol";

/// I27 / R2-M1 regression and the lockedValue lever behind P14.
///
/// HEAD: `setTranches` is REGISTRY-only (Registry.sol:435-437), `setTrancheWeights` rebuilds the
/// array from storage and only replaces weights (BaseMarket.sol:119-127), `createTranche` appends
/// most-junior (Registry.sol:177-199). Membership and order are therefore fixed for the owner.
///
/// What the owner still has: appending a junior. `lockedValue(senior)` (BaseMarket.sol:270-289)
/// = ceil(debt/(lt-buffer)) - sum(junior totalCapital), so a funded junior unlocks the senior
/// one-for-one and an underwriter allocator can exit the senior while the debt is outstanding.
contract C3_Waterfall is CapDeployer {
    address alice = makeAddr("alice");
    address juniorLp = makeAddr("juniorLp");
    address outsider = makeAddr("outsider");

    Underwriter uw;
    MarketBundle b;

    function setUp() public {
        _deployCap();
        b = _createReadyMarket("M");
        uw = _deployUnderwriter();
        _admitDepositor(b.tranche0Addr, address(uw));
        uw.addTranche(b.tranche0Addr);
    }

    function _weights3(uint256 a, uint256 c, uint256 d) internal pure returns (uint256[] memory w) {
        w = new uint256[](3);
        w[0] = a;
        w[1] = c;
        w[2] = d;
    }

    /// I27 (membership/order): the owner has no path to remove or reorder; only the registry may
    /// call setTranches and the registry only appends.
    function test_I27_ownerCannotChangeMembershipOrOrder() public {
        IBaseMarket.Tranche[] memory reordered = new IBaseMarket.Tranche[](2);
        reordered[0] = IBaseMarket.Tranche({ tranche: b.tranche1Addr, weight: 0.5e27 });
        reordered[1] = IBaseMarket.Tranche({ tranche: b.tranche0Addr, weight: 0.5e27 });

        vm.prank(defaultMarketOwner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, defaultMarketOwner));
        b.market.setTranches(reordered);

        // weights only: same addresses, same order
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e27;
        w[1] = 0.5e27;
        vm.prank(defaultMarketOwner);
        b.market.setTrancheWeights(w);
        IBaseMarket.Tranche[] memory after_ = b.market.tranches();
        assertEq(after_[0].tranche, b.tranche0Addr);
        assertEq(after_[1].tranche, b.tranche1Addr);

        // no protocol role can call setTranches either
        (bool guardianCan,) = accessManager.canCall(address(this), b.marketAddr, IBaseMarket.setTranches.selector);
        assertFalse(guardianCan, "GOVERNOR/GUARDIAN/KEEPER holder (this) cannot call setTranches");
        (bool registryCan,) = accessManager.canCall(address(registry), b.marketAddr, IBaseMarket.setTranches.selector);
        assertTrue(registryCan, "only the registry");
    }

    /// A tranche is bound to one market for life: `_setTranches` checks `market()` and
    /// `createTranche` deploys a fresh one wired to the caller's market.
    function test_I27_trancheCannotBeSharedAcrossMarkets() public {
        MarketBundle memory other = _createReadyMarket("N");
        assertEq(Tranche(other.tranche0Addr).market(), other.marketAddr);
        assertEq(b.tranche0.market(), b.marketAddr);
        // even the registry cannot insert b's tranche into `other`
        IBaseMarket.Tranche[] memory mixed = new IBaseMarket.Tranche[](1);
        mixed[0] = IBaseMarket.Tranche({ tranche: b.tranche0Addr, weight: 1e27 });
        vm.prank(address(registry));
        vm.expectRevert(IBaseMarket.InvalidMarket.selector);
        IBaseMarket(other.marketAddr).setTranches(mixed);
    }

    /// The lever: a funded appended junior reduces every senior's lockedValue one-for-one, and
    /// the underwriter allocator can then exit the senior in full while debt is outstanding.
    function test_lockedValue_appendedJuniorUnlocksSenior() public {
        _fundUnderwriter(address(uw), alice, 1_000e18);
        uw.allocate(b.tranche0Addr, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18); // activeCapital 1000 * ltv 0.5

        uint256 lockedBefore = b.market.lockedValue(b.tranche0Addr);
        uint256 unlockedBefore = b.tranche0.instantUnlockedSupply();
        // ceil(500e18 * 1e27 / 0.7e27) = 714.285714285714285715e18
        assertEq(lockedBefore, 714_285_714_285_714_285_715, "debt/(lt-buffer)");
        console.log("senior lockedValue with 500 debt, no junior capital:", lockedBefore);
        console.log("senior instantUnlockedSupply:                      ", unlockedBefore);

        // owner appends a third, most-junior tranche and a party funds it with 720
        uint256 w0 = b.market.tranches()[0].weight;
        uint256 w1 = b.market.tranches()[1].weight;
        vm.prank(defaultMarketOwner);
        address junior = registry.createTranche(b.marketAddr, address(collateral), _weights3(w0, w1, 0));
        _fundTranche(junior, juniorLp, 720e18);

        uint256 lockedAfter = b.market.lockedValue(b.tranche0Addr);
        uint256 unlockedAfter = b.tranche0.instantUnlockedSupply();
        console.log("senior lockedValue after 720 junior capital:       ", lockedAfter);
        console.log("senior instantUnlockedSupply after:                ", unlockedAfter);
        assertEq(lockedAfter, 0, "junior capital covers the whole requirement");

        // the underwriter exits the senior entirely while 500 of debt is outstanding
        uint256 freed = uw.deallocate(b.tranche0Addr, type(uint256).max);
        console.log("underwriter deallocated from senior (shares):      ", freed);
        console.log("senior totalAssets left:                           ", b.tranche0.totalAssets());
        console.log("market healthiness after (ray):                    ", b.market.healthiness());
        console.log("market totalCapital after:                         ", b.market.totalCapital());
        assertEq(b.tranche0.totalAssets(), DEAD_SHARES, "only the seed remains in the senior");
        assertGe(b.market.healthiness(), 1e27, "still healthy: the junior backs the debt alone");
        // the invariant that DOES hold: remaining capital >= debt/(lt-buffer)
        assertGe(b.market.totalCapital(), lockedBefore, "remaining capital covers debt/(lt-buffer)");
    }

    /// `_setTranches` reverts when unhealthy, so a fresh tranche cannot be appended to rescue an
    /// unhealthy market; only deposits into existing tranches or repayment can. Not a trap: the
    /// registry never calls it on its own, and `_createMarket` runs it on a debt-free market.
    function test_createTranche_revertsWhileUnhealthy() public {
        _fundUnderwriter(address(uw), alice, 1_000e18);
        uw.allocate(b.tranche0Addr, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);
        _setPrice(address(collateral), 0.5e18); // capital 500, threshold 400 < 500
        assertLt(b.market.healthiness(), 1e27);

        uint256 w0 = b.market.tranches()[0].weight;
        uint256 w1 = b.market.tranches()[1].weight;
        vm.prank(defaultMarketOwner);
        vm.expectRevert(IBaseMarket.Unhealthy.selector);
        registry.createTranche(b.marketAddr, address(collateral), _weights3(w0, w1, 0));
    }

    /// Queued-for-redemption shares: still in totalCapital (health) but out of activeCapital
    /// (credit). A depositor who queues everything zeroes new credit, leaves health untouched, and
    /// stays locked until the debt is gone; nothing forces the borrower to repay.
    function test_queuedSharesCountForHealthNotCredit() public {
        _fundTranche(b.tranche0Addr, alice, 1_000e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);

        vm.startPrank(alice);
        uint256 id = b.tranche0.requestRedeem(b.tranche0.balanceOf(alice), alice, alice);
        vm.stopPrank();

        console.log("totalCapital:        ", b.market.totalCapital());
        console.log("activeCapital:       ", b.tranche0.activeCapital());
        console.log("creditLimit:         ", b.market.creditLimit());
        console.log("healthiness (ray):   ", b.market.healthiness());
        console.log("alice claimable now: ", b.tranche0.claimableRedeemRequest(id, alice));
        // only the dead-share seed is still "active": credit collapses to 500 wei
        assertEq(b.tranche0.activeCapital(), DEAD_SHARES);
        assertEq(b.market.creditLimit(), DEAD_SHARES / 2, "no new credit beyond the seed");
        assertEq(b.market.healthiness(), 1.6e27, "existing debt fully covered");
        // supply (incl. seed) - ceil-quoted locked shares; the rest waits on the borrower
        assertEq(
            b.tranche0.claimableRedeemRequest(id, alice), 1_000e18 - 714_285_714_285_714_285_715, "unlocked slice only"
        );
    }
}
