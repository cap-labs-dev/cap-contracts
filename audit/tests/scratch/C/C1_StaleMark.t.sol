// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// WS-C / H2: Underwriter.totalAssets carries a mark-to-market `totalDebt` that is refreshed only
/// by allocate / deallocate* / report. redeem/withdraw/requestRedeem are not curator-gated, so a
/// depositor can exit at the pre-slash mark between a liquidation and the next KEEPER report.
contract C1_StaleMark is CapDeployer {
    FloatingMarket market;
    Tranche tranche0;
    Underwriter underwriter;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _deployCap();
        MarketBundle memory b = _createReadyMarket("M");
        market = b.market;
        tranche0 = b.tranche0;
        underwriter = _deployUnderwriter();
        _admitDepositor(address(tranche0), address(underwriter));
        underwriter.addTranche(address(tranche0));
        // no default tranche: curator allocates manually and keeps a liquid buffer idle
    }

    function test_H2_exitAtStaleMarkAfterSlash() public {
        _fundUnderwriter(address(underwriter), alice, 500e18);
        _fundUnderwriter(address(underwriter), bob, 500e18);
        underwriter.allocate(address(tranche0), 500e18); // 500 idle, 500 in tranche0

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 250e18); // health = 500*0.8/250 = 1.6

        oracle.setPrice(address(collateral), 0.6e18); // capital 300, LT 240 < debt 250
        assertLt(market.healthiness(), 1e27);

        uint256 repay = 100e18;
        _mintStable(defaultLiquidator, repay);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, repay); // slashes ~170 tokens (102 USD / 0.6)

        uint256 trancheAssets = tranche0.totalAssets();
        uint256 idle = vault.balanceOf(address(underwriter), address(collateral));
        uint256 trueAssets = idle + tranche0.previewRedeem(tranche0.balanceOf(address(underwriter)));
        uint256 staleAssets = underwriter.totalAssets();
        emit log_named_uint("tranche assets after slash (tokens)", trancheAssets);
        emit log_named_uint("underwriter true assets", trueAssets);
        emit log_named_uint("underwriter reported totalAssets (stale)", staleAssets);
        assertGt(staleAssets, trueAssets, "mark is stale");

        // Alice exits at the stale mark, paid out of the idle buffer. No curator/keeper action
        // is required and nothing in redeem() re-marks.
        uint256 aliceShares = underwriter.balanceOf(alice);
        uint256 fairAlice = aliceShares * trueAssets / underwriter.totalSupply();
        vm.prank(alice);
        uint256 alicePaid = underwriter.redeem(aliceShares, alice, alice);
        emit log_named_uint("alice fair share", fairAlice);
        emit log_named_uint("alice actually paid", alicePaid);

        // KEEPER now reports; Bob discovers he is holding the whole loss
        underwriter.report(address(tranche0));
        uint256 bobValue = underwriter.previewRedeem(underwriter.balanceOf(bob));
        emit log_named_uint("bob value after report", bobValue);
        emit log_named_uint("bob loss transferred from alice", fairAlice > bobValue ? fairAlice - bobValue : 0);

        assertLe(alicePaid, fairAlice + 1, "exiting depositor must not be paid above the true share price");
        assertGe(bobValue + 1, fairAlice, "remaining depositor must not absorb the exiting depositor's loss");
    }

    /// The reverse: unlockedSupply() = previewWithdraw(idle) also uses the stale price, and the
    /// queue path (requestRedeem -> redeem(requestId)) is priced by previewRedeem at claim time,
    /// so a queued depositor is paid at the stale mark too.
    function test_H2_queuedExitAlsoAtStaleMark() public {
        _fundUnderwriter(address(underwriter), alice, 500e18);
        _fundUnderwriter(address(underwriter), bob, 500e18);
        underwriter.allocate(address(tranche0), 500e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 250e18);

        uint256 aliceShares = underwriter.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = underwriter.requestRedeem(aliceShares, alice, alice);

        oracle.setPrice(address(collateral), 0.6e18);
        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 100e18);

        uint256 idle = vault.balanceOf(address(underwriter), address(collateral));
        uint256 trueAssets = idle + tranche0.previewRedeem(tranche0.balanceOf(address(underwriter)));
        uint256 fairAlice = aliceShares * trueAssets / underwriter.totalSupply();

        uint256 claimable = underwriter.claimableRedeemRequest(reqId, alice);
        vm.prank(alice);
        uint256 paid = underwriter.redeem(reqId, claimable, alice, alice);
        emit log_named_uint("alice queued claim paid", paid);
        emit log_named_uint("alice fair share", fairAlice);
        assertLe(paid, fairAlice + 1, "queued claim paid at stale mark");
    }
}
