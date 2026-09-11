// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-2 port of round-1 B1_OutOfOrderSettlement (H-2). Assertions unchanged.
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

        vm.prank(alice);
        senior.redeem(idA, 200e18, alice, alice);

        uint256 healthAfter = market.healthiness();
        emit log_named_uint("health after claim  (ray)", healthAfter);
        emit log_named_uint("maxLiquidatable          ", market.maxLiquidatable());
        assertGe(healthAfter, 1e27, "a redemption must never make a healthy market liquidatable");
    }
}
