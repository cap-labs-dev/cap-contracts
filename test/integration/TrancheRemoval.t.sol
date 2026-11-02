// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";

/// @notice A market owner can remove a tranche, including one whose feed has died, only while the
/// rest can back the debt; the removed tranche is retired and its holders can leave. A tranche
/// without live shares is never priced, so a dead feed behind one cannot freeze its market.
contract TrancheRemovalTest is CapDeployer {
    MarketBundle internal bundle;
    MockERC20 internal risky;
    Tranche internal swap;
    address internal seniorLp = makeAddr("senior");
    address internal swapLp = makeAddr("swap");

    /// @dev 500 of debt against 1,000 of the approved collateral in the senior, and a third
    /// tranche in another asset holding 1,000. The exit lock is 500 / 0.7 = 714.29.
    function setUp() public {
        _deployCap();
        bundle = _createReadyMarket("Removal");
        _fundTranche(bundle.tranche0Addr, seniorLp, 1_000e18);
        vm.prank(defaultBorrower);
        bundle.market.borrow(defaultBorrower, 500e18);

        uint256[] memory weights = new uint256[](3);
        weights[0] = 0.9e27;
        weights[1] = 0.05e27;
        weights[2] = 0.05e27;
        risky = _newCollateral("Risky", "RSK", 18, 1e18);
        swap = Tranche(bundle.market.createTranche(address(risky), weights, 12 hours));
        _fundTranche(address(swap), address(risky), swapLp, 1_000e18);
    }

    function _removeSenior() internal {
        bundle.market.removeTranche(bundle.tranche0Addr, _halves());
    }

    function _halves() internal pure returns (uint256[] memory weights) {
        weights = new uint256[](2);
        weights[0] = 0.5e27;
        weights[1] = 0.5e27;
    }

    function _killFeed(address asset) internal {
        oracle.setSource(asset, new IOracle.Sources[](0));
    }

    /// A tranche whose holders are locked can go once the rest can carry its lock: it is retired,
    /// the tranches above it take the lock over, and its holders leave in full.
    function test_removeTranche_handsItsLockToTheRest() public {
        swap.setMaxCapital(1_000e18);
        assertApproxEqAbs(bundle.market.lockedValue(address(swap)), 714285714285714285715, 1, "it backs the debt");
        assertEq(bundle.market.lockedValue(bundle.tranche0Addr), 0, "and frees the senior");
        uint256 shares = swap.balanceOf(swapLp);
        assertLt(swap.maxInstantRedeem(swapLp), shares, "so its holders are locked");

        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.95e27;
        weights[1] = 0.05e27;
        vm.expectEmit(address(swap));
        emit ITranche.Killed();
        vm.expectEmit(bundle.marketAddr);
        emit IBaseMarket.RemoveTranche(address(swap));
        bundle.market.removeTranche(address(swap), weights);

        IBaseMarket.Tranche[] memory listed = bundle.market.tranches();
        assertEq(listed.length, 2, "slot freed");
        assertEq(listed[0].tranche, bundle.tranche0Addr, "order kept");
        assertEq(listed[1].tranche, bundle.tranche1Addr);
        assertTrue(swap.killed(), "retired");
        assertEq(swap.maxDeposit(swapLp), 0, "takes no deposits");

        assertEq(bundle.market.lockedValue(address(swap)), 0, "backs nothing");
        assertApproxEqAbs(
            bundle.market.lockedValue(bundle.tranche0Addr), 714285714285714285715, 1, "the senior takes it over"
        );
        assertEq(swap.maxInstantRedeem(swapLp), shares, "every share can leave");
        vm.prank(swapLp);
        swap.instantRedeem(shares, swapLp, swapLp);
    }

    /// Removal is held to the exit lock, not to health: the rest must back the debt at
    /// `LT - buffer`, each counted only up to its cap.
    function test_removeTranche_revertsWhenTheRestCannotBackTheDebt() public {
        swap.setMaxCapital(700e18);
        assertGe(bundle.market.healthiness(), 1e27);

        vm.expectRevert(IBaseMarket.Undercovered.selector);
        _removeSenior();
    }

    /// The removal route to the swap: a tranche governance has not priced in cannot take over
    /// the debt from the collateral it approved.
    function test_removeTranche_cannotMoveTheDebtOntoAnUncappedTranche() public {
        assertEq(swap.maxCapital(), 0);
        assertGt(swap.totalCapital(), 714.3e18, "holds more than the lock");

        vm.expectRevert(IBaseMarket.Undercovered.selector);
        _removeSenior();
    }

    /// A phased-out collateral whose feed has died can be removed without its price, and the
    /// market carries on.
    function test_removeTranche_worksAfterItsFeedDies() public {
        swap.setMaxCapital(1_000e18);
        _killFeed(address(collateral));
        vm.expectRevert(ITranche.InvalidPrice.selector);
        bundle.market.healthiness();

        _removeSenior();

        assertGe(bundle.market.healthiness(), 1e27, "priced without the dead feed");
        assertEq(bundle.tranche0.unlockedSupply(), bundle.tranche0.totalSupply(), "holders free without a price");
        uint256 shares = bundle.tranche0.balanceOf(seniorLp);
        vm.prank(seniorLp);
        bundle.tranche0.instantRedeem(shares, seniorLp, seniorLp);
    }

    function test_removeTranche_rejectsAnUnlistedTrancheAndBadWeights() public {
        vm.expectRevert(IBaseMarket.TrancheNotSet.selector);
        bundle.market.removeTranche(makeAddr("stranger tranche"), _halves());

        vm.expectRevert(IBaseMarket.InvalidTrancheCount.selector);
        bundle.market.removeTranche(bundle.tranche0Addr, new uint256[](1));
    }

    /// A middle tranche: the ones after it shift up one slot and keep their order.
    function test_removeTranche_fromTheMiddle() public {
        swap.setMaxCapital(1_000e18);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.9e27;
        weights[1] = 0.1e27;
        bundle.market.removeTranche(bundle.tranche1Addr, weights);

        IBaseMarket.Tranche[] memory listed = bundle.market.tranches();
        assertEq(listed.length, 2);
        assertEq(listed[0].tranche, bundle.tranche0Addr);
        assertEq(listed[0].weight, 0.9e27);
        assertEq(listed[1].tranche, address(swap));
        assertEq(listed[1].weight, 0.1e27);
        assertTrue(bundle.tranche1.killed());
    }

    function test_removeTranche_onlyMarketOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        _removeSenior();
    }

    function test_retire_onlyMarket() public {
        vm.expectRevert(ITranche.InvalidMarket.selector);
        swap.retire();
    }

    /// Once every holder has left, the dead shares' backing and a dust donation are unowned. They
    /// are not priced, so a dead feed behind them cannot stop the market's liquidations.
    function test_trancheWithoutLiveSharesNeedsNoPrice() public {
        // clear the debt so the holder can leave, then draw it again
        vm.prank(defaultBorrower);
        bundle.market.repay(type(uint256).max);
        uint256 shares = swap.balanceOf(swapLp);
        vm.prank(swapLp);
        swap.instantRedeem(shares, swapLp, swapLp);
        vm.prank(defaultBorrower);
        bundle.market.borrow(defaultBorrower, 500e18);
        assertEq(swap.totalSupply(), 1_000, "only the dead shares remain");
        risky.mint(address(this), 1);
        assertTrue(risky.transfer(address(swap), 1));
        assertGt(swap.totalAssets(), 0, "a residue and a donation");

        _killFeed(address(risky));
        assertEq(swap.totalCapital(), 0, "unowned residue is not priced");
        assertEq(swap.activeCapital(), 0);
        vm.prank(bundle.marketAddr);
        assertEq(swap.slash(1e18, address(this)), 0, "nothing anyone owns to slash");

        _setPrice(address(collateral), 0.6e18);
        assertLt(bundle.market.healthiness(), 1e27, "the senior's price fell");
        uint256 repay = bundle.market.maxLiquidatable() / 2;
        _mintStable(defaultLiquidator, repay);
        vm.prank(defaultLiquidator);
        (uint256 repaid,) = bundle.market.liquidate(defaultLiquidator, repay);
        assertEq(repaid, repay, "liquidation still runs");
    }

    /// Live shares are still priced, so a funded tranche is never quietly valued at zero.
    function test_trancheWithLiveSharesStillNeedsItsPrice() public {
        _killFeed(address(risky));
        vm.expectRevert(ITranche.InvalidPrice.selector);
        swap.totalCapital();
        vm.expectRevert(ITranche.InvalidPrice.selector);
        swap.activeCapital();
    }
}
