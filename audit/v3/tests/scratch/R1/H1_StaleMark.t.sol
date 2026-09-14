// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 H-1 (C1_StaleMark / R1_H1_StaleMark) to HEAD a843c1d.
/// API changes only: `previewRedeem` reverts on HEAD -> `convertToAssets`; instant exit is
/// `instantRedeem`; `_setPrice` harness. Assertions unchanged in meaning.
///
/// Underwriter.totalAssets() = idle vault balance + cached `totalDebt` (Underwriter.sol:243-245);
/// `_mark` runs only in allocate/deallocate*/report (:187-203). Between a slash and the next mark
/// every exit is priced at the stale (pre-slash) book. HEAD NatSpec now calls this intentional
/// ("A slash between reports is a loss that waits here on purpose", :182-183).
contract R1_H1_StaleMark is CapDeployer {
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
        // no default tranche: allocator allocates manually and keeps a liquid buffer idle
    }

    function _trueAssets() internal view returns (uint256) {
        uint256 idle = vault.balanceOf(address(underwriter), address(collateral));
        return idle + tranche0.convertToAssets(tranche0.balanceOf(address(underwriter)));
    }

    function test_H1_exitAtStaleMarkAfterSlash() public {
        _fundUnderwriter(address(underwriter), alice, 500e18);
        _fundUnderwriter(address(underwriter), bob, 500e18);
        underwriter.allocate(address(tranche0), 500e18); // 500 idle, 500 in tranche0

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 250e18); // health = 500*0.8/250 = 1.6

        _setPrice(address(collateral), 0.6e18); // capital 300, LT 240 < debt 250
        assertLt(market.healthiness(), 1e27);

        uint256 repay = 100e18;
        _mintStable(defaultLiquidator, repay);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, repay); // slashes ~170 tokens (102 USD / 0.6)

        uint256 trueAssets = _trueAssets();
        uint256 staleAssets = underwriter.totalAssets();
        emit log_named_uint("tranche assets after slash (tokens)", tranche0.totalAssets());
        emit log_named_uint("underwriter true assets", trueAssets);
        emit log_named_uint("underwriter reported totalAssets (stale)", staleAssets);
        assertGt(staleAssets, trueAssets, "mark is stale");

        // Alice exits at the stale mark, paid out of the idle buffer. No allocator/keeper action
        // is required and nothing in instantRedeem() re-marks.
        uint256 aliceShares = underwriter.balanceOf(alice);
        uint256 fairAlice = aliceShares * trueAssets / underwriter.totalSupply();
        emit log_named_uint("alice maxInstantRedeem (shares)", underwriter.maxInstantRedeem(alice));
        vm.prank(alice);
        uint256 alicePaid = underwriter.instantRedeem(aliceShares, alice, alice);
        emit log_named_uint("alice fair share", fairAlice);
        emit log_named_uint("alice actually paid", alicePaid);

        // KEEPER now reports; Bob discovers he is holding the whole loss
        underwriter.report(address(tranche0));
        uint256 bobValue = underwriter.convertToAssets(underwriter.balanceOf(bob));
        emit log_named_uint("bob value after report", bobValue);
        emit log_named_uint("bob loss transferred from alice", fairAlice > bobValue ? fairAlice - bobValue : 0);

        assertLe(alicePaid, fairAlice + 1, "exiting depositor must not be paid above the true share price");
        assertGe(bobValue + 1, fairAlice, "remaining depositor must not absorb the exiting depositor's loss");
    }

    /// The queue path (requestRedeem -> redeem(requestId)) is priced by convertToAssets at claim
    /// time off the same stale book, so a queued depositor is paid at the stale mark too.
    function test_H1_queuedExitAlsoAtStaleMark() public {
        _fundUnderwriter(address(underwriter), alice, 500e18);
        _fundUnderwriter(address(underwriter), bob, 500e18);
        underwriter.allocate(address(tranche0), 500e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 250e18);

        uint256 aliceShares = underwriter.balanceOf(alice);
        vm.prank(alice);
        uint256 reqId = underwriter.requestRedeem(aliceShares, alice, alice);

        _setPrice(address(collateral), 0.6e18);
        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 100e18);

        uint256 trueAssets = _trueAssets();
        uint256 fairAlice = aliceShares * trueAssets / underwriter.totalSupply();

        uint256 claimable = underwriter.claimableRedeemRequest(reqId, alice);
        vm.prank(alice);
        uint256 paid = underwriter.redeem(reqId, claimable, alice, alice);
        emit log_named_uint("alice queued claim paid", paid);
        emit log_named_uint("alice fair share", fairAlice);
        assertLe(paid, fairAlice + 1, "queued claim paid at stale mark");
    }

    /// Round-3 addition (third-party stance): no permissionless re-mark exists. `report` is KEEPER,
    /// `allocate`/`deallocate` are the allocator role, and a plain share transfer to a never-admitted
    /// address still exits at the stale price.
    function test_H1_noPermissionlessRemark_transfereeExitsAtStalePrice() public {
        _fundUnderwriter(address(underwriter), alice, 500e18);
        _fundUnderwriter(address(underwriter), bob, 500e18);
        underwriter.allocate(address(tranche0), 500e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 250e18);
        _setPrice(address(collateral), 0.6e18);
        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 100e18);

        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        underwriter.report(address(tranche0));

        address transferee = makeAddr("never-admitted");
        uint256 shares = underwriter.balanceOf(alice);
        vm.prank(alice);
        underwriter.transfer(transferee, shares);
        uint256 fair = shares * _trueAssets() / underwriter.totalSupply();
        vm.prank(transferee);
        uint256 paid = underwriter.instantRedeem(shares, transferee, transferee);
        emit log_named_uint("transferee paid", paid);
        emit log_named_uint("transferee fair", fair);
        assertLe(paid, fair + 1, "never-admitted transferee exits at the stale mark");
    }
}
