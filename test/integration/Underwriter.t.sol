// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "./CapDeployer.sol";

/// @notice End-to-end curator flow: a depositor supplies to the Underwriter, which allocates into a
/// tranche that backs loans, earns premium rewards, and settles async redemptions by deallocating.
contract UnderwriterIntegrationTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal depositor = makeAddr("depositor");

    bytes32 internal marketId;
    Tranche internal senior;
    Tranche internal junior;
    Underwriter internal underwriter;

    uint256 internal constant DEPOSIT = 1_000e18;

    function setUp() public {
        _deployCap();

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        address s;
        address j;
        (marketId, s, j) = _createMarket("Market A", borrowers);
        senior = Tranche(s);
        junior = Tranche(j);

        // rate curves so that borrowing accrues supply + premium interest
        _setMarketSlopes(marketId);
        irm.setVariableSlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        lender.setMultiplier(marketId, 1e27);
        vm.prank(address(senior));
        lender.setJuniorSplit(marketId, 0.5e27);
        lender.setBorrowCap(marketId, 1_000e18);

        // the curator vault pays rewards in cUSD and is allowed to deposit into the senior tranche
        underwriter = _deployUnderwriter();
        senior.setWhitelist(address(underwriter), true);
    }

    /// @dev Route underwriter deposits into the senior tranche automatically.
    function _useSeniorAsDefault() internal {
        underwriter.setDefaultTranche(address(senior));
    }

    // --- allocation ---

    function test_deposit_allocatesToDefaultTranche() public {
        _useSeniorAsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        // depositor holds underwriter shares
        assertEq(underwriter.balanceOf(depositor), DEPOSIT);
        // the underwriter forwarded the collateral into the senior tranche
        assertEq(senior.balanceOf(address(underwriter)), DEPOSIT);
        assertEq(vault.balanceOf(address(senior), address(collateral)), DEPOSIT);
        // nothing left idle in the underwriter's vault balance -> fully allocated
        assertEq(vault.balanceOf(address(underwriter), address(collateral)), 0);
        assertEq(underwriter.totalAssets(), DEPOSIT);
    }

    function test_manualAllocateDeallocate_roundtrips() public {
        // no default tranche: the deposit stays idle in the underwriter until allocated manually
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

    // --- rewards from backing loans ---

    function test_curatorEarnsPremiumAndDistributesToDepositor() public {
        _useSeniorAsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        // a borrower draws against the credit backed by the underwriter's tranche position
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 400e18);

        vm.warp(block.timestamp + 365 days);

        // curator pulls the accrued premium (cUSD) into the underwriter and starts vesting it
        underwriter.report(address(senior));
        uint256 pulled = stablecoin.balanceOf(address(underwriter));
        assertGt(pulled, 0);

        // before vesting completes the depositor has not received anything yet
        assertEq(stablecoin.balanceOf(depositor), 0);

        // after the vesting window the depositor claims their share of the premium
        vm.warp(block.timestamp + 6 hours);
        uint256 claimable = underwriter.claimableReward(depositor);
        assertApproxEqAbs(claimable, pulled, 1e6);

        vm.prank(depositor);
        underwriter.claim();

        assertApproxEqAbs(stablecoin.balanceOf(depositor), pulled, 1e6);
        assertApproxEqAbs(stablecoin.balanceOf(address(underwriter)), 0, 1e6);
    }

    // --- async redemption: pending while allocated, settled after deallocation ---

    function test_asyncRedemption_pendingUntilDeallocated() public {
        _useSeniorAsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        // fully allocated -> the underwriter holds no instantly redeemable liquidity
        assertEq(underwriter.unlockedSupply(), 0);

        vm.prank(depositor);
        uint256 reqId = underwriter.requestRedeem(DEPOSIT, depositor, depositor);

        // the request sits pending because all assets are working in the tranche
        assertEq(underwriter.pendingRedeemRequest(reqId, depositor), DEPOSIT);
        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), 0);

        // curator frees liquidity by pulling assets back out of the tranche
        uint256 shares = senior.balanceOf(address(underwriter));
        uint256 freed = underwriter.deallocate(address(senior), shares);
        assertEq(freed, DEPOSIT);

        // now the depositor's request is fully claimable and can be redeemed for collateral
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
        lender.borrow(marketId, borrower, 400e18);

        vm.prank(depositor);
        uint256 reqId = underwriter.requestRedeem(DEPOSIT, depositor, depositor);
        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), 0);

        // while the loan is outstanding the tranche only frees part of its collateral
        uint256 shares = senior.balanceOf(address(underwriter));
        uint256 partialFreed = underwriter.deallocate(address(senior), shares);
        assertGt(partialFreed, 0);
        assertLt(partialFreed, DEPOSIT);

        // some of the request becomes claimable, but not all of it yet
        uint256 claimablePartial = underwriter.claimableRedeemRequest(reqId, depositor);
        assertGt(claimablePartial, 0);
        assertLt(claimablePartial, DEPOSIT);

        // repay the debt to unlock the remaining tranche collateral
        _mintStable(borrower, 1_000e18);
        vm.prank(borrower);
        lender.repay(marketId, type(uint256).max);

        uint256 remaining = senior.balanceOf(address(underwriter));
        underwriter.deallocate(address(senior), remaining);

        // the entire request is now claimable
        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), DEPOSIT);

        vm.prank(depositor);
        underwriter.redeem(reqId, DEPOSIT, depositor, depositor);
        assertEq(vault.balanceOf(depositor, address(collateral)), DEPOSIT);
    }
}
