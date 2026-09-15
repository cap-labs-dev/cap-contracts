// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../../../../contracts/interfaces/IBaseMarket.sol";
import { ITranche } from "../../../../../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../../../test/shared/mocks/MockERC20.sol";

/// Independent verification of D-1: does a single dead feed on a funded, STAKED tranche block
/// floating `repay`, and is there any non-GOVERNOR way for the borrower to exit debt?
contract V_D1_DeadFeedRepay is CapDeployer {
    FloatingMarket market;
    address senior;
    address mid;
    address junior;
    MockERC20 x;
    address midDepositor = makeAddr("m");

    function _setUpMarket(bool stakeMid) internal {
        _deployCap();
        x = _newCollateral("X", "X", 18, 1e18);
        address[] memory assets = new address[](3);
        assets[0] = address(collateral);
        assets[1] = address(x);
        assets[2] = address(collateral);
        uint256[] memory weights = new uint256[](3);
        weights[0] = 0.5e27;
        weights[1] = 0.3e27;
        weights[2] = 0.2e27;
        (address m, address[] memory tranches) =
            _createMarket("VD1", defaultMarketOwner, defaultBorrower, assets, weights);
        market = FloatingMarket(m);
        senior = tranches[0];
        mid = tranches[1];
        junior = tranches[2];
        _setMarketSlopes(m);
        market.setFixedCreditLimit(1_000_000e18);
        _fundTranche(senior, address(collateral), makeAddr("s"), 400e18);
        if (stakeMid) {
            _fundTranche(mid, address(x), midDepositor, 300e18);
        } else {
            // deposit without optIn: stakedSupply stays 0
            MockERC20(address(x)).mint(midDepositor, 300e18);
            vm.startPrank(midDepositor);
            x.approve(address(vault), 300e18);
            vault.deposit(address(x), 300e18, midDepositor);
            vault.setOperator(mid, true);
            vm.stopPrank();
            _admitDepositor(mid, midDepositor);
            vm.prank(midDepositor);
            Tranche(mid).deposit(300e18, midDepositor);
        }
        _fundTranche(junior, address(collateral), makeAddr("j"), 300e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
        skip(1 hours);
    }

    function _killMidFeed() internal {
        _setStaleness(address(x), 1 hours);
        skip(2 hours);
        assertEq(oracle.price(address(x)), 0, "feed dead");
    }

    /// (1) Precondition check: the revert needs the dead tranche to be STAKED. Not staked -> repay works.
    function test_unstakedDeadTranche_repayWorks() public {
        _setUpMarket(false);
        assertEq(Tranche(mid).stakedSupply(), 0);
        assertGt(Tranche(mid).totalAssets(), 0);
        _killMidFeed();
        _mintStable(defaultBorrower, 500e18);
        vm.prank(defaultBorrower);
        market.repay(type(uint256).max);
        assertEq(market.totalDebt(), 0, "repay works when the dead tranche has no staked shares");
    }

    /// (2) Staked dead tranche: full, partial and 1-wei repay all revert. chargePremium too.
    function test_stakedDeadTranche_everyRepayReverts() public {
        _setUpMarket(true);
        _killMidFeed();
        _mintStable(defaultBorrower, 500e18);
        bytes4 e = ITranche.InvalidPrice.selector;
        vm.startPrank(defaultBorrower);
        vm.expectRevert(e);
        market.repay(type(uint256).max);
        vm.expectRevert(e);
        market.repay(100e18);
        vm.expectRevert(e);
        market.repay(1);
        vm.stopPrank();
        vm.expectRevert(e);
        market.chargePremium();
        vm.prank(defaultMarketOwner);
        vm.expectRevert(e);
        market.setMarketMultiplier(1.5e27);
    }

    /// (3) Escape via UW rate = 0? No: updateUnderwriterRate snapshots the index, the accrued
    /// premium is still > 0 on the next charge, and _earnsPremium still prices the dead tranche.
    function test_underwriterRateZero_doesNotUnblockRepay() public {
        _setUpMarket(true);
        _killMidFeed();
        vm.prank(defaultMarketOwner);
        market.setUnderwriterRate(0);
        (, uint256 uwPremium) = market.premium();
        assertGt(uwPremium, 0, "accrued premium survives the rate change");
        _mintStable(defaultBorrower, 500e18);
        vm.prank(defaultBorrower);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.repay(type(uint256).max);
    }

    /// (4) Non-GOVERNOR mitigation: the dead tranche's stakers can optOut (no price consulted),
    /// dropping stakedSupply to 0, after which repay/chargePremium work again. Liquidation, writeOff
    /// and borrow remain bricked (they walk totalCapital). Depositors of the dead tranche are third
    /// parties, so this is cooperation, not a borrower-controlled path.
    function test_optOutByDeadTrancheStakers_restoresRepayOnly() public {
        _setUpMarket(true);
        _killMidFeed();
        vm.prank(midDepositor);
        Tranche(mid).optOut();
        assertEq(Tranche(mid).stakedSupply(), 0);

        market.chargePremium();
        _mintStable(defaultBorrower, 500e18);
        vm.prank(defaultBorrower);
        uint256 repaid = market.repay(200e18);
        assertApproxEqAbs(repaid, 200e18, 1, "partial repay works once no share is staked in the dead tranche");

        bytes4 e = ITranche.InvalidPrice.selector;
        vm.expectRevert(e);
        market.healthiness();
        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        vm.expectRevert(e);
        market.liquidate(defaultLiquidator, 100e18);
        vm.expectRevert(e);
        market.writeOff();
        vm.prank(defaultBorrower);
        vm.expectRevert(e);
        market.borrow(defaultBorrower, 1e18);

        vm.prank(defaultBorrower);
        market.repay(type(uint256).max);
        assertEq(market.totalDebt(), 0, "full exit");
    }

    /// (5) Market owner cannot drop the dead tranche: setTranches is REGISTRY-only, and
    /// setTrancheWeights / createTranche re-run healthiness() which prices it.
    function test_marketOwnerCannotRemoveDeadTranche() public {
        _setUpMarket(true);
        _killMidFeed();
        uint256[] memory w = new uint256[](3);
        w[0] = 0.5e27;
        w[1] = 0;
        w[2] = 0.5e27;
        vm.prank(defaultMarketOwner);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.setTrancheWeights(w);

        IBaseMarket.Tranche[] memory t = new IBaseMarket.Tranche[](2);
        t[0] = IBaseMarket.Tranche({ tranche: senior, weight: 0.5e27 });
        t[1] = IBaseMarket.Tranche({ tranche: junior, weight: 0.5e27 });
        vm.prank(defaultMarketOwner);
        vm.expectRevert();
        market.setTranches(t);
    }

    /// (6) Even weight-0 tranches are priced by _earnsPremium (loop does not skip zero weight).
    function test_zeroWeightDeadTranche_stillReverts() public {
        _setUpMarket(true);
        uint256[] memory w = new uint256[](3);
        w[0] = 0.5e27;
        w[1] = 0;
        w[2] = 0.5e27;
        vm.prank(defaultMarketOwner);
        market.setTrancheWeights(w);
        _killMidFeed();
        _mintStable(defaultBorrower, 500e18);
        vm.prank(defaultBorrower);
        vm.expectRevert(ITranche.InvalidPrice.selector);
        market.repay(type(uint256).max);
    }
}
