// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 H-2 (B1_OutOfOrderSettlement / R1_H2_OutOfOrderSettlement) to HEAD.
/// The three round-1 tests are kept with their assertions; a fourth test probes the residual
/// the round-3 lead asked about: with the per-request clamp (ERC7540AsyncRedeem.sol:355) and the
/// live check in `_claim` (:434-435), is the out-of-order over-credit gone or merely bounded?
contract R1_H2_OutOfOrderSettlement is CapDeployer {
    address internal supplier = makeAddr("supplier");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");

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

    function test_B1_juniorClaimSucceedsWhileUnlockedSupplyIsZero() public {
        _fundTranche(address(senior), supplier, 1_000e18);
        _fundTranche(address(junior), alice, 100e18); // alice pays the seed
        _fundTranche(address(junior), bob, 100e18);

        uint256 aliceShares = junior.balanceOf(alice);
        vm.prank(alice);
        uint256 idA = junior.requestRedeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 idB = junior.requestRedeem(100e18, bob, bob);

        assertEq(junior.claimableRedeemRequest(idA, alice), aliceShares);
        assertEq(junior.claimableRedeemRequest(idB, bob), 100e18);

        // Bob settles OUT OF ORDER (Alice is earlier and still open)
        vm.prank(bob);
        junior.redeem(idB, 100e18, bob, bob);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);

        uint256 unlocked = junior.unlockedSupply();
        uint256 claimable = junior.claimableRedeemRequest(idA, alice);
        emit log_named_uint("junior.unlockedSupply()          ", unlocked);
        emit log_named_uint("junior.claimable(idA, alice)     ", claimable);
        emit log_named_uint("junior.totalAssets() before claim", junior.totalAssets());
        emit log_named_uint("market.lockedValue(junior)       ", market.lockedValue(address(junior)));

        assertEq(unlocked, 0, "junior is fully locked by the debt");
        assertLe(claimable, unlocked, "claimable must never exceed unlockedSupply");
    }

    function test_B1_juniorClaimDrainsLockedTranche() public {
        _fundTranche(address(senior), supplier, 1_000e18);
        _fundTranche(address(junior), alice, 100e18);
        _fundTranche(address(junior), bob, 100e18);

        uint256 aliceShares = junior.balanceOf(alice);
        vm.prank(alice);
        uint256 idA = junior.requestRedeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 idB = junior.requestRedeem(100e18, bob, bob);
        vm.prank(bob);
        junior.redeem(idB, 100e18, bob, bob);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);
        assertEq(junior.unlockedSupply(), 0);

        uint256 before = vault.balanceOf(alice, address(collateral));
        vm.prank(alice);
        vm.expectRevert(); // a locked tranche must not pay out
        junior.redeem(idA, aliceShares, alice, alice);
        assertEq(vault.balanceOf(alice, address(collateral)), before, "alice must not have been paid");
    }

    function test_B1_seniorExitFlipsHealthyMarketToLiquidatable() public {
        _fundTranche(address(senior), supplier, 800e18); // pays seed
        _fundTranche(address(senior), alice, 200e18);
        assertEq(senior.balanceOf(alice), 200e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max); // 500e18 = ltv * 1000
        emit log_named_uint("debt", market.totalDebt());

        vm.prank(alice);
        uint256 idA = senior.requestRedeem(200e18, alice, alice);
        assertEq(senior.claimableRedeemRequest(idA, alice), 200e18, "alice fully claimable at request time");

        address[3] memory churners = [carol, dave, erin];
        for (uint256 i; i < 3; ++i) {
            _fundTranche(address(senior), churners[i], 80e18);
            vm.startPrank(churners[i]);
            uint256 id = senior.requestRedeem(80e18, churners[i], churners[i]);
            senior.redeem(id, 80e18, churners[i], churners[i]);
            vm.stopPrank();
        }

        _setPrice(address(collateral), 0.7e18);
        assertEq(senior.unlockedSupply(), 0, "lock binds");
        uint256 healthBefore = market.healthiness();
        assertGe(healthBefore, 1e27, "market healthy before the claim");
        emit log_named_uint("health before claim (ray)", healthBefore);
        emit log_named_uint("alice claimable          ", senior.claimableRedeemRequest(idA, alice));

        // round 1: this call succeeded and drained the lock. On HEAD it must revert; the
        // health assertion below is the round-1 property either way.
        vm.prank(alice);
        (bool ok,) = address(senior)
            .call(abi.encodeWithSignature("redeem(uint256,uint256,address,address)", idA, 200e18, alice, alice));
        emit log_named_string("alice claim while locked", ok ? "PAID" : "reverted");

        uint256 healthAfter = market.healthiness();
        emit log_named_uint("health after claim  (ray)", healthAfter);
        emit log_named_uint("maxLiquidatable          ", market.maxLiquidatable());
        assertGe(healthAfter, 1e27, "a redemption must never make a healthy market liquidatable");
    }

    /// Residual probe: `settledQueue` is total claimed, not a contiguous prefix. A later request
    /// that settles first still shifts the watermark for every earlier open window, so the SUM of
    /// `claimableRedeemRequest` across controllers can exceed `unlockedSupply()` (the round-1 I17
    /// view invariant). The per-request clamp and `_claim`'s live check bound every PAYOUT to live
    /// liquidity, so the drain is gone; what remains is an over-stated view and a claim that reverts
    /// for whoever comes second.
    function test_H2_residual_sumClaimableExceedsUnlocked_butPayoutBounded() public {
        _fundTranche(address(senior), supplier, 1_000e18); // pays seed
        _fundTranche(address(senior), alice, 200e18);
        _fundTranche(address(senior), bob, 100e18);
        _fundTranche(address(senior), carol, 100e18);

        // no debt yet: everything is claimable; three windows [0,200) [200,300) [300,400)
        vm.prank(alice);
        uint256 idA = senior.requestRedeem(200e18, alice, alice);
        vm.prank(bob);
        uint256 idB = senior.requestRedeem(100e18, bob, bob);
        vm.prank(carol);
        uint256 idC = senior.requestRedeem(100e18, carol, carol);

        // Carol (latest) claims first: settledQueue = 100 although the head of the queue is open
        vm.prank(carol);
        senior.redeem(idC, 100e18, carol, carol);

        // debt appears and the price moves so that only ~261 shares are unlocked
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
        _setPrice(address(collateral), 0.55e18);
        assertGe(market.healthiness(), 1e27, "market healthy");

        uint256 unlocked = senior.unlockedSupply();
        uint256 cA = senior.claimableRedeemRequest(idA, alice);
        uint256 cB = senior.claimableRedeemRequest(idB, bob);
        emit log_named_uint("unlockedSupply           ", unlocked);
        emit log_named_uint("claimable A (window 0)   ", cA);
        emit log_named_uint("claimable B (window 200) ", cB);
        emit log_named_uint("sum claimable            ", cA + cB);
        // each request is individually clamped to live liquidity ...
        assertLe(cA, unlocked, "per-request clamp");
        assertLe(cB, unlocked, "per-request clamp");
        // ... but the watermark was shifted by Carol's out-of-order claim, so the views over-credit
        emit log_named_string(
            "sum claimable <= unlocked (I17 view invariant)", cA + cB <= unlocked ? "holds" : "VIOLATED"
        );

        // payouts: Alice takes her 200 (she is first), Bob's advertised 100 is not deliverable
        vm.prank(alice);
        senior.redeem(idA, cA, alice, alice);
        uint256 unlockedAfterA = senior.unlockedSupply();
        emit log_named_uint("unlocked after A's claim ", unlockedAfterA);
        vm.prank(bob);
        (bool ok,) =
            address(senior).call(abi.encodeWithSignature("redeem(uint256,uint256,address,address)", idB, cB, bob, bob));
        emit log_named_string("bob claims his advertised amount", ok ? "PAID" : "reverted (ExceededMaxRedeem)");
        uint256 cB2 = senior.claimableRedeemRequest(idB, bob);
        emit log_named_uint("bob claimable now        ", cB2);
        if (cB2 > 0) {
            vm.prank(bob);
            senior.redeem(idB, cB2, bob, bob);
        }
        // the round-1 harm: never below the lock, never liquidatable
        assertEq(senior.unlockedSupply(), 0, "liquidity fully consumed, never over-drawn");
        assertGe(market.healthiness(), 1e27, "market still healthy after both claims");
        assertEq(market.maxLiquidatable(), 0);
        // the residual: the advertised sum was not deliverable
        assertLe(cA + cB, unlocked, "sum of advertised claimable must be deliverable");
    }
}
