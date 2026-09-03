// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

contract UnderwriterIntegrationTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal depositor = makeAddr("depositor");
    FloatingMarket internal market;
    Tranche internal tranche0;
    Tranche internal tranche1;
    Underwriter internal underwriter;

    uint256 internal constant DEPOSIT = 1_000e18;

    function setUp() public {
        _deployCap();

        address marketAddr;
        address t0;
        address t1;
        (marketAddr, t0, t1) = _createMarket("Market A");
        market = FloatingMarket(marketAddr);
        tranche0 = Tranche(t0);
        tranche1 = Tranche(t1);

        _setMarketSlopes(marketAddr);
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        market.setMarketMultiplier(1e27);
        market.setFixedCreditLimit(1_000e18);

        underwriter = _deployUnderwriter();
        tranche0.setWhitelist(address(underwriter), true);
    }

    function _useTranche0AsDefault() internal {
        underwriter.addTranche(address(tranche0));
        underwriter.setDefaultTranche(address(tranche0));
    }

    function test_deposit_allocatesToDefaultTranche() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        assertEq(underwriter.balanceOf(depositor), DEPOSIT);
        assertEq(tranche0.balanceOf(address(underwriter)), DEPOSIT);
        assertEq(vault.balanceOf(address(tranche0), address(collateral)), DEPOSIT);
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), 0);
        assertEq(underwriter.totalAssets(), DEPOSIT);
    }

    function test_manualAllocateDeallocate_roundtrips() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), DEPOSIT);

        underwriter.addTranche(address(tranche0));
        underwriter.allocate(address(tranche0), DEPOSIT);
        assertEq(tranche0.balanceOf(address(underwriter)), DEPOSIT);
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), 0);

        uint256 freed = underwriter.deallocate(address(tranche0), DEPOSIT);
        assertEq(freed, DEPOSIT);
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), DEPOSIT);
    }

    function test_deallocate_afterRemoveTranche() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        underwriter.addTranche(address(tranche0));
        underwriter.allocate(address(tranche0), DEPOSIT);
        assertEq(tranche0.balanceOf(address(underwriter)), DEPOSIT);

        underwriter.removeTranche(address(tranche0));

        vm.expectRevert(IUnderwriter.NotRegisteredTranche.selector);
        underwriter.allocate(address(tranche0), 1e18);

        uint256 freed = underwriter.deallocate(address(tranche0), DEPOSIT);
        assertEq(freed, DEPOSIT);
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), DEPOSIT);
    }

    function test_allocate_nonTranche_reverts() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);
        vm.expectRevert(IUnderwriter.NotRegisteredTranche.selector);
        underwriter.allocate(makeAddr("notTranche"), 1e18);
    }

    function test_curatorEarnsPremiumAndDistributesToDepositor() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        market.chargePremium();

        vm.warp(block.timestamp + 6 hours);

        underwriter.report(address(tranche0));
        uint256 pulled = stablecoin.balanceOf(address(underwriter));
        assertGt(pulled, 0);

        assertEq(stablecoin.balanceOf(depositor), 0);

        vm.warp(block.timestamp + 6 hours);
        uint256 claimable = underwriter.claimable(depositor);
        assertGt(claimable, 0);

        vm.prank(depositor);
        underwriter.claim();

        assertApproxEqAbs(stablecoin.balanceOf(depositor), claimable, 1e6);
        assertApproxEqAbs(stablecoin.balanceOf(address(underwriter)), 0, 1e6);
    }

    function test_asyncRedemption_pendingUntilDeallocated() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        assertEq(underwriter.unlockedSupply(), 0);

        vm.prank(depositor);
        uint256 reqId = underwriter.requestRedeem(DEPOSIT, depositor, depositor);

        assertEq(underwriter.pendingRedeemRequest(reqId, depositor), DEPOSIT);
        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), 0);

        uint256 shares = tranche0.balanceOf(address(underwriter));
        uint256 freed = underwriter.deallocate(address(tranche0), shares);
        assertEq(freed, DEPOSIT);

        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), DEPOSIT);

        vm.prank(depositor);
        uint256 assets = underwriter.redeem(reqId, DEPOSIT, depositor, depositor);
        assertEq(assets, DEPOSIT);
        assertEq(vault.balanceOf(depositor, address(collateral)), DEPOSIT);
        assertEq(underwriter.totalSupply(), 0);
    }

    function test_asyncRedemption_partialWhileBorrowed_fullAfterRepay() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.prank(depositor);
        uint256 reqId = underwriter.requestRedeem(DEPOSIT, depositor, depositor);
        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), 0);

        uint256 shares = tranche0.balanceOf(address(underwriter));
        uint256 partialFreed = underwriter.deallocate(address(tranche0), shares);
        assertGt(partialFreed, 0);
        assertLt(partialFreed, DEPOSIT);

        uint256 claimablePartial = underwriter.claimableRedeemRequest(reqId, depositor);
        assertGt(claimablePartial, 0);
        assertLt(claimablePartial, DEPOSIT);

        _mintStable(borrower, 1_000e18);
        vm.prank(borrower);
        market.repay(type(uint256).max);

        uint256 remaining = tranche0.balanceOf(address(underwriter));
        underwriter.deallocate(address(tranche0), remaining);

        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), DEPOSIT);

        vm.prank(depositor);
        underwriter.redeem(reqId, DEPOSIT, depositor, depositor);
        assertEq(vault.balanceOf(depositor, address(collateral)), DEPOSIT);
    }
}
