// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../../../contracts/cap/InterestRateModel.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice Killing tests for accrual-ordering survivors (plan I16 / I30).
///
/// Gambit `FloatingMarket#17` deletes `_chargePremium()` in {FloatingMarket-borrow};
/// Gambit `FloatingMarket#29` deletes it in {FloatingMarket-writeOff}; hand mutant H23 drops the
/// index checkpoint in {InterestRateModel-updateUnderwriterRate}. All three survive the stock
/// suite because every existing scenario calls `chargePremium()` explicitly before the action, or
/// acts in the same block as the last charge. The property each test pins is the master
/// invariant I30: after any market action, `totalDebt() == creditBackedSupply()` (single market).
contract FloatingAccrualKillTest is CapDeployer {
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployCap();
    }

    /// Kills FloatingMarket#17. A borrow made after time has elapsed since the last checkpoint
    /// must first mint the premium accrued on the old principal; otherwise the next charge mints
    /// that premium on the *new* principal as well and credit-backed supply outruns debt.
    function test_borrowAfterElapsedTimeKeepsDebtEqualToCredit() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 10_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);

        vm.warp(block.timestamp + 30 days);
        uint256 projected = b.market.totalDebt();
        assertGt(projected, 400e18, "interest has accrued but is not yet minted");

        // no explicit chargePremium(): the borrow itself has to checkpoint first
        vm.prank(defaultBorrower);
        uint256 minted = b.market.borrow(defaultBorrower, 100e18);

        assertEq(b.market.totalDebt(), projected + minted, "debt is the projected debt plus the draw");
        assertEq(b.market.totalDebt(), stablecoin.creditBackedSupply(), "credit-backed supply equals debt");

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        assertEq(b.market.totalDebt(), stablecoin.creditBackedSupply(), "and stays equal after the next charge");
    }

    /// Kills FloatingMarket#29. A write-off after time has elapsed must mint the premium accrued
    /// up to that block before it retires scaled debt; otherwise the written-off principal's
    /// accrued premium is never minted and debt permanently exceeds credit-backed supply, so the
    /// last unit of debt can never be repaid (burnCreditBacked would underflow).
    function test_writeOffAfterElapsedTimeKeepsDebtEqualToCredit() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);

        vm.warp(block.timestamp + 30 days);
        assertGt(b.market.totalDebt(), 500e18, "interest has accrued");

        _setPrice(address(collateral), 0.1e18);
        uint256 written = b.market.writeOff();
        assertGt(written, 0, "something was written off");

        assertEq(b.market.totalDebt(), stablecoin.creditBackedSupply(), "credit-backed supply equals debt");
        assertEq(stablecoin.badDebt(), written, "the write-off is the recognised loss");

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        assertEq(b.market.totalDebt(), stablecoin.creditBackedSupply(), "no permanent gap after the next charge");
    }

    /// Kills H23. Changing the underwriter rate must checkpoint the index at its accrued value so
    /// outstanding debt does not jump (down) when the market owner reprices.
    function test_underwriterRateChangeDoesNotRewriteAccruedDebt() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 10_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 1_000e18);

        vm.warp(block.timestamp + 180 days);
        uint256 before = b.market.totalDebt();
        uint256 indexBefore = irm.underwriterIndex(b.marketAddr);
        // 20 % for half a year on 1000: about 105 of underwriter premium is outstanding
        assertGt(indexBefore, 1.1e27, "the underwriter index has grown");

        b.market.setUnderwriterRate(0.05e27);

        assertEq(irm.underwriterIndex(b.marketAddr), indexBefore, "the index is checkpointed, not reset");
        assertEq(b.market.totalDebt(), before, "outstanding debt is unchanged by a rate change");

        b.market.chargePremium();
        assertEq(b.market.totalDebt(), stablecoin.creditBackedSupply(), "and the accrued premium is minted");
    }
}
