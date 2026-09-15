// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @title B1 - out-of-order queue settlement over-credits earlier requests
/// @notice claimableRedeemRequest treats `settledQueue + unlockedSupply()` as a cumulative
/// liquidity high-water mark. `settledQueue` counts shares settled ANYWHERE in the queue, so a
/// later request that claims while an earlier one is still open permanently raises the earlier
/// request's claimable figure by the amount settled, regardless of where unlockedSupply() moves
/// afterwards. For Tranche/Underwriter unlockedSupply() moves exogenously (borrow, accrual, price,
/// allocate), so the earlier request can then be claimed while unlockedSupply()==0, i.e. past the
/// market's lock.
contract B1_OutOfOrderSettlement is CapDeployer {
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

    /// @dev Junior tranche: two requesters, both fully claimable while there is no debt. Bob claims,
    /// borrower then draws to the limit which locks the whole junior tranche. Alice's request is
    /// still reported fully claimable and can be claimed with unlockedSupply()==0.
    function test_B1_juniorClaimSucceedsWhileUnlockedSupplyIsZero() public {
        _fundTranche(address(senior), supplier, 1_000e18);
        _fundTranche(address(junior), alice, 100e18); // alice pays the seed
        _fundTranche(address(junior), bob, 100e18);

        uint256 aliceShares = junior.balanceOf(alice);
        vm.prank(alice);
        uint256 idA = junior.requestRedeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 idB = junior.requestRedeem(100e18, bob, bob);

        // no debt: everything is unlocked, both windows are inside [0, currentIndex)
        assertEq(junior.claimableRedeemRequest(idA, alice), aliceShares);
        assertEq(junior.claimableRedeemRequest(idB, bob), 100e18);

        // Bob settles OUT OF ORDER (Alice is earlier and still open)
        vm.prank(bob);
        junior.redeem(idB, 100e18, bob, bob);

        // Borrower draws to the limit. Junior lock = debt/(lt-buffer) >> junior capital
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);

        uint256 unlocked = junior.unlockedSupply();
        uint256 claimable = junior.claimableRedeemRequest(idA, alice);
        emit log_named_uint("junior.unlockedSupply()          ", unlocked);
        emit log_named_uint("junior.claimable(idA, alice)     ", claimable);
        emit log_named_uint("junior.totalAssets() before claim", junior.totalAssets());
        emit log_named_uint("market.lockedValue(junior)       ", market.lockedValue(address(junior)));

        assertEq(unlocked, 0, "junior is fully locked by the debt");

        // THE BUG: claimable is credited with Bob's out-of-order settlement
        assertLe(claimable, unlocked, "claimable must never exceed unlockedSupply");
    }

    /// @dev Same defect, claimed through: the claim goes through and drains the junior tranche
    /// while the market says it is locked. (Split from the test above so both assertions get a
    /// real run.)
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

    /// @dev Senior-only market at max borrow. Alice queues 200 while 285 is unlocked and leaves it.
    /// Three later requesters churn 80 each (deposit -> request -> claim), each adding 80 to
    /// settledQueue. Collateral then falls 30% so the lock binds exactly (unlocked == 0) with the
    /// market still healthy at lt/(lt-buffer). Alice claims her 200 anyway and the market flips to
    /// liquidatable - the buffer exists precisely to make that impossible.
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

        // three churners settle out of order behind alice
        address[3] memory churners = [carol, dave, erin];
        for (uint256 i; i < 3; ++i) {
            _fundTranche(address(senior), churners[i], 80e18);
            vm.startPrank(churners[i]);
            uint256 id = senior.requestRedeem(80e18, churners[i], churners[i]);
            senior.redeem(id, 80e18, churners[i], churners[i]);
            vm.stopPrank();
        }

        // collateral drops 30%: lockedAssets = debt/(0.7 * 0.7) > totalAssets -> unlocked = 0
        oracle.setPrice(address(collateral), 0.7e18);
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
