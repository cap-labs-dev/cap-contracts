// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "./CapDeployer.sol";

/// @notice Exercises the ERC-7540 async redemption queue for every vault that uses it: the Tranche
/// (locked by outstanding debt) and the Stablecoin (locked by unbacked supply). The Underwriter's
/// async queue is covered in Underwriter.t.sol.
contract AsyncRedemptionTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal supplier = makeAddr("supplier");
    address internal cusdHolder = makeAddr("cusdHolder");
    address internal cusdDepositor = makeAddr("cusdDepositor");

    function setUp() public {
        _deployCap();
    }

    // --- Tranche: redemptions queue while collateral backs a live loan ---

    function test_tranche_asyncRedemption_pendingUntilRepaid() public {
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        (bytes32 marketId, address s,) = _createMarket("Market A", borrowers);
        Tranche senior = Tranche(s);

        _setMarketSlopes(marketId);
        irm.setVariableSlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        lender.setBorrowCap(marketId, 1_000e18);

        // fund the senior tranche and draw the full available credit against it
        _fundTranche(s, supplier, 1_000e18);
        vm.prank(borrower);
        lender.borrow(marketId, borrower, 500e18);

        // request to redeem everything: only the unlocked portion is immediately claimable
        vm.prank(supplier);
        uint256 reqId = senior.requestRedeem(1_000e18, supplier, supplier);

        uint256 claimablePartial = senior.claimableRedeemRequest(reqId, supplier);
        assertGt(claimablePartial, 0);
        assertLt(claimablePartial, 1_000e18);
        assertGt(senior.pendingRedeemRequest(reqId, supplier), 0);

        // repay the loan to release the locked collateral
        _mintStable(borrower, 1_000e18);
        vm.prank(borrower);
        lender.repay(marketId, type(uint256).max);

        // the full request is now claimable and redeemable for collateral
        assertEq(senior.claimableRedeemRequest(reqId, supplier), 1_000e18);

        vm.prank(supplier);
        uint256 assets = senior.redeem(reqId, 1_000e18, supplier, supplier);
        assertEq(assets, 1_000e18);
        assertEq(vault.balanceOf(supplier, address(collateral)), 1_000e18);
        assertEq(senior.totalSupply(), 0);
    }

    // --- Stablecoin: redemptions queue while supply is unbacked ---

    function test_stablecoin_asyncRedemption_pendingUntilBacked() public {
        // a holder receives unbacked cUSD (as a borrower would); there is no underlying to redeem yet
        _mintStable(cusdHolder, 100e18);
        assertEq(stablecoin.unlockedSupply(), 0);

        vm.prank(cusdHolder);
        uint256 reqId = stablecoin.requestRedeem(100e18, cusdHolder, cusdHolder);

        assertEq(stablecoin.pendingRedeemRequest(reqId, cusdHolder), 100e18);
        assertEq(stablecoin.claimableRedeemRequest(reqId, cusdHolder), 0);

        // someone deposits real underlying, backing the supply and unlocking redemptions
        cusdUnderlying.mint(cusdDepositor, 100e18);
        vm.startPrank(cusdDepositor);
        cusdUnderlying.approve(address(stablecoin), 100e18);
        stablecoin.deposit(100e18, cusdDepositor);
        vm.stopPrank();

        assertEq(stablecoin.unlockedSupply(), 100e18);
        assertEq(stablecoin.claimableRedeemRequest(reqId, cusdHolder), 100e18);

        // the holder now redeems the queued request for the underlying asset
        vm.prank(cusdHolder);
        uint256 assets = stablecoin.redeem(reqId, 100e18, cusdHolder, cusdHolder);
        assertEq(assets, 100e18);
        assertEq(cusdUnderlying.balanceOf(cusdHolder), 100e18);
    }

    // --- Stablecoin: instant redemption path when backing already exists ---

    function test_stablecoin_instantRedeem_whenBacked() public {
        cusdUnderlying.mint(cusdDepositor, 100e18);
        vm.startPrank(cusdDepositor);
        cusdUnderlying.approve(address(stablecoin), 100e18);
        stablecoin.deposit(100e18, cusdDepositor);

        // fully backed supply -> shares are instantly redeemable without queueing
        assertEq(stablecoin.maxRedeem(cusdDepositor), 100e18);
        uint256 assets = stablecoin.redeem(100e18, cusdDepositor, cusdDepositor);
        vm.stopPrank();

        assertEq(assets, 100e18);
        assertEq(cusdUnderlying.balanceOf(cusdDepositor), 100e18);
    }
}
