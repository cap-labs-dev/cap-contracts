// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../contracts/interfaces/IBaseMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// @notice Independent verification of B-1. Differs from the workstream PoC in that every request
/// is made while the tranche is LOCKED (claimable == 0, so the async path is the only exit), the
/// unlock is an ordinary borrower repayment, the out-of-order claim is just a faster claimant,
/// the re-lock is a price move, and the loss is realised by the production LIQUIDATOR role.
contract OutOfOrderVerify is CapDeployer {
    address internal supplier = makeAddr("supplier");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    FloatingMarket internal market;
    Tranche internal senior;
    Tranche internal junior;

    function setUp() public {
        _deployCap();
        (address m, address s, address j) = _createMarket("Market A");
        market = FloatingMarket(m);
        senior = Tranche(s);
        junior = Tranche(j);
        _setMarketSlopes(m);
        market.setFixedCreditLimit(type(uint256).max);
    }

    /// @dev Both requests made while locked; repay unlocks both; Bob (later) claims first; price
    /// falls so the lock binds exactly at the buffer floor; Alice claims through it; a LIQUIDATOR
    /// then slashes the supplier. Without Alice's claim, liquidate() reverts Healthy.
    function test_organic_slowClaimant_exitsPastLock_thenLiquidation() public {
        _fundTranche(address(senior), supplier, 800e18);
        _fundTranche(address(senior), alice, 200e18);
        _fundTranche(address(senior), bob, 200e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max); // 600
        assertEq(market.totalDebt(), 600e18);

        // price 0.7 -> lockedAssets = 600/0.7/0.7 = 1224 > 1200 -> fully locked, health 1.12
        oracle.setPrice(address(collateral), 0.7e18);
        assertEq(senior.unlockedSupply(), 0, "locked at request time");
        assertEq(senior.maxRedeem(alice), 0, "instant exit unavailable");

        vm.prank(alice);
        uint256 idA = senior.requestRedeem(200e18, alice, alice);
        vm.prank(bob);
        uint256 idB = senior.requestRedeem(200e18, bob, bob);
        assertEq(senior.claimableRedeemRequest(idA, alice), 0, "alice pending");
        assertEq(senior.claimableRedeemRequest(idB, bob), 0, "bob pending");

        // borrower repays 250 -> debt 350 -> lockedAssets = 350/0.7/0.7 = 714 -> unlocked 486
        _mintStable(defaultBorrower, 250e18);
        vm.prank(defaultBorrower);
        market.repay(250e18);
        assertEq(senior.claimableRedeemRequest(idA, alice), 200e18, "alice fully claimable");
        assertEq(senior.claimableRedeemRequest(idB, bob), 200e18, "bob fully claimable");

        // Bob is faster
        vm.prank(bob);
        senior.redeem(idB, 200e18, bob, bob);

        // price 0.5 -> lockedAssets = 350/0.7/0.5 = 1000 == totalAssets -> unlocked 0
        // health = 1000*0.5*0.8/350 = 1.1428 = lt/(lt-buffer): the designed post-redemption floor
        oracle.setPrice(address(collateral), 0.5e18);
        assertEq(senior.unlockedSupply(), 0, "re-locked");
        uint256 healthBefore = market.healthiness();
        emit log_named_uint("health before (ray)", healthBefore);
        assertGe(healthBefore, 1e27);

        // liquidation impossible before the claim
        _mintStable(defaultLiquidator, 1_000e18);
        vm.prank(defaultLiquidator);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        market.liquidate(defaultLiquidator, type(uint256).max);

        // over-credit: alice's window [0,200) is credited with bob's 200 settled at [200,400)
        uint256 claimable = senior.claimableRedeemRequest(idA, alice);
        emit log_named_uint("alice claimable with unlocked==0", claimable);
        assertEq(claimable, 200e18);

        uint256 aliceBefore = vault.balanceOf(alice, address(collateral));
        vm.prank(alice);
        senior.redeem(idA, 200e18, alice, alice);
        assertEq(vault.balanceOf(alice, address(collateral)) - aliceBefore, 200e18, "alice paid past the lock");

        uint256 healthAfter = market.healthiness();
        emit log_named_uint("health after  (ray)", healthAfter);
        assertLt(healthAfter, 1e27, "market now liquidatable");

        // LIQUIDATOR (production role) now slashes the supplier
        uint256 supplierValueBefore = senior.previewRedeem(senior.balanceOf(supplier));
        uint256 liqCollBefore = collateral.balanceOf(defaultLiquidator);
        uint256 liqStableBefore = stablecoin.balanceOf(defaultLiquidator);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(defaultLiquidator, type(uint256).max);
        uint256 supplierValueAfter = senior.previewRedeem(senior.balanceOf(supplier));
        emit log_named_uint("debt repaid by liquidator", repaid);
        emit log_named_uint("collateral slashed (units)", slashed);
        emit log_named_uint("supplier collateral before", supplierValueBefore);
        emit log_named_uint("supplier collateral after ", supplierValueAfter);
        uint256 liqGain = collateral.balanceOf(defaultLiquidator) - liqCollBefore;
        uint256 liqCost = liqStableBefore - stablecoin.balanceOf(defaultLiquidator);
        emit log_named_uint("liquidator collateral received (units)", liqGain);
        emit log_named_uint("liquidator cUSD burned", liqCost);
        // bonus in USD: collateral at 0.5 minus cUSD at par
        emit log_named_uint("liquidator bonus (USD)", liqGain * 0.5e18 / 1e18 - liqCost);
        assertGt(supplierValueBefore - supplierValueAfter, 0, "supplier slashed");
        assertGe(market.healthiness(), 1e27);
    }

    /// @dev The over-credit is bounded by min(request, shares settled behind it) + live unlocked.
    function test_bound_isSettledBehindPlusUnlocked() public {
        _fundTranche(address(senior), supplier, 800e18);
        _fundTranche(address(senior), alice, 200e18);
        _fundTranche(address(senior), bob, 50e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max); // 525

        vm.prank(alice);
        uint256 idA = senior.requestRedeem(200e18, alice, alice);
        vm.prank(bob);
        uint256 idB = senior.requestRedeem(50e18, bob, bob);
        vm.prank(bob);
        senior.redeem(idB, 50e18, bob, bob); // settledQueue = 50

        // lock fully: lockedAssets = 525/0.7/p >= 1000 -> p <= 0.75
        oracle.setPrice(address(collateral), 0.7e18);
        assertEq(senior.unlockedSupply(), 0);
        assertEq(senior.claimableRedeemRequest(idA, alice), 50e18, "over-credit == settled behind");

        // partial lock: p = 0.8 -> lockedAssets = 937.5 -> unlocked 62.5
        oracle.setPrice(address(collateral), 0.8e18);
        uint256 u = senior.unlockedSupply();
        assertEq(senior.claimableRedeemRequest(idA, alice), 50e18 + u, "settled behind + live unlocked");
        emit log_named_uint("unlocked", u);
        emit log_named_uint("claimable", senior.claimableRedeemRequest(idA, alice));
    }

    /// @dev A request that is fully claimable at request time could have been an instant redeem of
    /// the same size, and queued shares earn nothing, so the 'deliberate pre-credit' path B is
    /// dominated by simply exiting unless the actor also wants to force a liquidation.
    function test_deliberatePath_requiresForgoingInstantExit() public {
        _fundTranche(address(senior), supplier, 800e18);
        _fundTranche(address(senior), alice, 200e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);

        assertGe(senior.maxRedeem(alice), 200e18, "instant exit of the full amount was available");
        uint256 stakedBefore = senior.stakedSupply();
        vm.prank(alice);
        senior.requestRedeem(200e18, alice, alice);
        assertEq(senior.stakedSupply(), stakedBefore - 200e18, "queued shares stop earning premium");
        // and the borrower cannot re-lock a queued SENIOR position by borrowing: the credit limit
        // is sized off activeCapital, which already excludes the queue
        vm.prank(defaultBorrower);
        vm.expectRevert();
        market.borrow(defaultBorrower, 1);
    }

    /// @dev Junior flavour: a borrow (not a price move) is enough to re-lock the junior queue, and
    /// the claim through it leaves the senior as first loss without moving health below 1.
    function test_junior_reborrowRelocks_claimShiftsFirstLoss() public {
        _fundTranche(address(senior), supplier, 1_000e18);
        _fundTranche(address(junior), alice, 100e18);
        _fundTranche(address(junior), bob, 100e18);
        uint256 aliceShares = junior.balanceOf(alice);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max); // 600, junior fully locked
        assertEq(junior.unlockedSupply(), 0);
        vm.prank(alice);
        uint256 idA = junior.requestRedeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 idB = junior.requestRedeem(100e18, bob, bob);

        _mintStable(defaultBorrower, 600e18);
        vm.prank(defaultBorrower);
        market.repay(type(uint256).max);
        vm.prank(bob);
        junior.redeem(idB, 100e18, bob, bob);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max); // 500 (junior queue excluded from limit)
        assertEq(junior.unlockedSupply(), 0, "junior re-locked by borrow alone");
        assertEq(junior.claimableRedeemRequest(idA, alice), aliceShares);
        vm.prank(alice);
        junior.redeem(idA, aliceShares, alice, alice);
        emit log_named_uint("junior capital after exit", junior.totalCapital());
        emit log_named_uint("health after junior exit (ray)", market.healthiness());
        assertGe(market.healthiness(), 1e27, "still healthy: harm is first-loss shift, not liquidation");
    }
}
