// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice Borrowing and realizing earned premium cannot subsidize an otherwise identical exit.
contract ShortfallPricingTest is CapDeployer {
    FloatingMarket internal premiumMarket;
    FloatingMarket internal drawMarket;
    address internal alice = makeAddr("redeemer");

    struct Outcome {
        uint256 paid;
        uint256 burned;
        uint256 badDebt;
        uint256 reserve;
        uint256 supply;
        uint256 credit;
        uint256 queued;
    }

    function setUp() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.applyLiquiditySlopes = true;
        _deployCapWithConfig(cfg);
        _depositStable(alice, 1_000e18);
        MarketBundle memory b = _createReadyMarket("Premium");
        _fundTranche(b.tranche0Addr, makeAddr("premiumUnderwriter"), 1_000e18);
        premiumMarket = b.market;
        b = _createReadyMarket("Temporary draw");
        _fundTranche(b.tranche0Addr, makeAddr("drawUnderwriter"), 1_000e18);
        drawMarket = b.market;

        vm.prank(defaultBorrower);
        premiumMarket.borrow(defaultBorrower, 100e18);
        cusdUnderlying.burn(address(stablecoin), 200e18);
        stablecoin.recognizeBadDebtInReserve(200e18);
        vm.warp(block.timestamp + 30 days);
    }

    /// @dev Baseline: exit, then realize premium. Comparison: realize the same premium, borrow,
    /// make the identical exit, then repay. Time is fixed so the only difference is credit issuance
    /// around settlement. FIFO claims cover multiple receipts for larger exact-asset withdrawals.
    function testFuzz_borrowExitRepayMatchesDirectExit(uint96 rawAmount, bool queued, bool withdrawAssets) public {
        uint256 amount = bound(rawAmount, 1e18, 300e18);
        if (queued) {
            vm.startPrank(alice);
            stablecoin.requestRedeem(200e18, alice, alice);
            stablecoin.requestRedeem(400e18, alice, alice);
            vm.stopPrank();
        }
        uint256 snapshot = vm.snapshotState();
        (uint256 paid, uint256 burned) = _exit(amount, queued, withdrawAssets);
        premiumMarket.chargePremium();
        Outcome memory direct = _outcome(paid, burned);
        assertGt(stablecoin.remaining(), 0, "real liquidity premium was credit-minted");
        vm.revertToState(snapshot);

        premiumMarket.chargePremium();
        vm.prank(defaultBorrower);
        uint256 borrowed = drawMarket.borrow(defaultBorrower, 200e18);
        (paid, burned) = _exit(amount, queued, withdrawAssets);
        vm.prank(defaultBorrower);
        assertEq(drawMarket.repay(type(uint256).max), borrowed, "temporary loan is fully repaid");
        Outcome memory withCredit = _outcome(paid, burned);

        assertEq(withCredit.paid, direct.paid, "same payout");
        assertEq(withCredit.burned, direct.burned, "same shares burned");
        assertEq(withCredit.badDebt, direct.badDebt, "same bad debt retired");
        assertEq(withCredit.reserve, direct.reserve, "same final reserve balance");
        assertEq(withCredit.supply, direct.supply, "same final supply");
        assertEq(withCredit.credit, direct.credit, "same final performing credit");
        assertEq(withCredit.queued, direct.queued, "same pending shares");
        assertEq(stablecoin.creditBackedSupply(), premiumMarket.totalDebt());
        assertEq(drawMarket.totalDebt(), 0);
    }

    function test_borrowerExhaustingReserveStillOwesTheLoan() public {
        _setMaxCapital(drawMarket, 4_000e18);
        _fundTranche(drawMarket.tranches()[0].tranche, makeAddr("additionalUnderwriter"), 3_000e18);
        premiumMarket.chargePremium();
        vm.prank(defaultBorrower);
        uint256 borrowed = drawMarket.borrow(defaultBorrower, 1_000e18);
        uint256 creditBefore = stablecoin.creditBackedSupply();

        for (uint256 i; i < 16; ++i) {
            uint256 shares = stablecoin.maxInstantRedeem(defaultBorrower);
            if (shares == 0) break;
            vm.prank(defaultBorrower);
            stablecoin.instantRedeem(shares, defaultBorrower, defaultBorrower);
            assertEq(drawMarket.totalDebt(), borrowed, "redemption does not repay the loan");
            assertEq(stablecoin.creditBackedSupply(), creditBefore);
            assertLe(stablecoin.badDebt() + creditBefore, stablecoin.totalSupply());
        }
        assertEq(cusdUnderlying.balanceOf(defaultBorrower), 800e18);
        assertEq(cusdUnderlying.balanceOf(address(stablecoin)), 0);
        assertEq(stablecoin.badDebt(), 0);
        assertEq(stablecoin.totalSupply(), creditBefore, "remaining holders are entirely credit-backed");
        assertEq(stablecoin.balanceOf(alice), 1_000e18);
        assertEq(stablecoin.maxInstantRedeem(alice), 0);
    }

    function _exit(uint256 amount, bool queued, bool withdrawAssets) internal returns (uint256 paid, uint256 burned) {
        vm.startPrank(alice);
        if (withdrawAssets) {
            paid = amount;
            burned =
                queued ? stablecoin.withdraw(amount, alice, alice) : stablecoin.instantWithdraw(amount, alice, alice);
        } else {
            burned = amount;
            paid = queued ? stablecoin.redeem(amount, alice, alice) : stablecoin.instantRedeem(amount, alice, alice);
        }
        vm.stopPrank();
    }

    function _outcome(uint256 paid, uint256 burned) internal view returns (Outcome memory) {
        return Outcome({
            paid: paid,
            burned: burned,
            badDebt: stablecoin.badDebt(),
            reserve: cusdUnderlying.balanceOf(address(stablecoin)),
            supply: stablecoin.totalSupply(),
            credit: stablecoin.creditBackedSupply(),
            queued: stablecoin.redemptionQueue()
        });
    }
}
