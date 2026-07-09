// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Market } from "../../contracts/cap/Market.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "./CapDeployer.sol";

contract UnderwriterIntegrationTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal depositor = makeAddr("depositor");
    uint64 internal managerId = MANAGER_ROLE;
    uint64 internal borrowerId = BORROWER_ROLE;
    Market internal market;
    Tranche internal senior;
    Tranche internal junior;
    Underwriter internal underwriter;

    uint256 internal constant DEPOSIT = 1_000e18;

    function setUp() public {
        _deployCap();

        address marketAddr;
        address s;
        address j;
        (marketAddr, s, j) = _createMarket("Market A", managerId, borrowerId);
        accessManager.grantRole(BORROWER_ROLE, borrower, 0);
        market = Market(marketAddr);
        senior = Tranche(s);
        junior = Tranche(j);

        _setMarketSlopes(marketAddr);
        irm.setVariableSlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        market.setMultiplier(1e27);
        market.setJuniorSplit(0.5e27);
        market.setBorrowCap(1_000e18);

        underwriter = _deployUnderwriter();
        senior.setWhitelist(address(underwriter), true);
    }

    function _useSeniorAsDefault() internal {
        underwriter.setDefaultTranche(address(senior));
    }

    function test_deposit_allocatesToDefaultTranche() public {
        _useSeniorAsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        assertEq(underwriter.balanceOf(depositor), DEPOSIT);
        assertEq(senior.balanceOf(address(underwriter)), DEPOSIT);
        assertEq(vault.balanceOf(address(senior), address(collateral)), DEPOSIT);
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), 0);
        assertEq(underwriter.totalAssets(), DEPOSIT);
    }

    function test_manualAllocateDeallocate_roundtrips() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), DEPOSIT);

        underwriter.allocate(address(senior), DEPOSIT);
        assertEq(senior.balanceOf(address(underwriter)), DEPOSIT);
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), 0);

        uint256 freed = underwriter.deallocate(address(senior), DEPOSIT);
        assertEq(freed, DEPOSIT);
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), DEPOSIT);
    }

    function test_allocate_nonTranche_reverts() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);
        vm.expectRevert(IUnderwriter.InvalidTranche.selector);
        underwriter.allocate(makeAddr("notTranche"), 1e18);
    }

    function test_curatorEarnsPremiumAndDistributesToDepositor() public {
        _useSeniorAsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.warp(block.timestamp + 365 days);

        underwriter.report(address(senior));
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
        _useSeniorAsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        assertEq(underwriter.unlockedSupply(), 0);

        vm.prank(depositor);
        uint256 reqId = underwriter.requestRedeem(DEPOSIT, depositor, depositor);

        assertEq(underwriter.pendingRedeemRequest(reqId, depositor), DEPOSIT);
        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), 0);

        uint256 shares = senior.balanceOf(address(underwriter));
        uint256 freed = underwriter.deallocate(address(senior), shares);
        assertEq(freed, DEPOSIT);

        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), DEPOSIT);

        vm.prank(depositor);
        uint256 assets = underwriter.redeem(reqId, DEPOSIT, depositor, depositor);
        assertEq(assets, DEPOSIT);
        assertEq(vault.balanceOf(depositor, address(collateral)), DEPOSIT);
        assertEq(underwriter.totalSupply(), 0);
    }

    function test_asyncRedemption_partialWhileBorrowed_fullAfterRepay() public {
        _useSeniorAsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.prank(depositor);
        uint256 reqId = underwriter.requestRedeem(DEPOSIT, depositor, depositor);
        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), 0);

        uint256 shares = senior.balanceOf(address(underwriter));
        uint256 partialFreed = underwriter.deallocate(address(senior), shares);
        assertGt(partialFreed, 0);
        assertLt(partialFreed, DEPOSIT);

        uint256 claimablePartial = underwriter.claimableRedeemRequest(reqId, depositor);
        assertGt(claimablePartial, 0);
        assertLt(claimablePartial, DEPOSIT);

        _mintStable(borrower, 1_000e18);
        vm.prank(borrower);
        market.repay(type(uint256).max);

        uint256 remaining = senior.balanceOf(address(underwriter));
        underwriter.deallocate(address(senior), remaining);

        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), DEPOSIT);

        vm.prank(depositor);
        underwriter.redeem(reqId, DEPOSIT, depositor, depositor);
        assertEq(vault.balanceOf(depositor, address(collateral)), DEPOSIT);
    }
}
