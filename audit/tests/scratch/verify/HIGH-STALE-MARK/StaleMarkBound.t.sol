// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// Verification of HIGH-STALE-MARK: quantify the bound, check the idle-cap, the default-tranche
/// re-mark path, and the ungated exit for a transferee.
contract StaleMarkBound is CapDeployer {
    FloatingMarket market;
    Tranche tranche0;
    Underwriter uw;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address outsider = makeAddr("outsider");

    function setUp() public {
        _deployCap();
        MarketBundle memory b = _createReadyMarket("M");
        market = b.market;
        tranche0 = b.tranche0;
        uw = _deployUnderwriter();
        _admitDepositor(address(tranche0), address(uw));
        uw.addTranche(address(tranche0));
    }

    function _slashViaLiquidation() internal returns (uint256 lossTokens) {
        uint256 before = tranche0.totalAssets();
        uint256 borrow = before / 2; // health 1.6 at price 1
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, borrow);
        oracle.setPrice(address(collateral), 0.6e18); // LT 0.48*cap < 0.5*cap
        uint256 repay = borrow * 2 / 5;
        _mintStable(defaultLiquidator, repay);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, repay);
        lossTokens = before - tranche0.totalAssets();
    }

    function _idle() internal view returns (uint256) {
        return vault.balanceOf(address(uw), address(collateral));
    }

    /// (b) fully allocated: the idle balance is zero, so nothing can leave at the stale mark
    function test_fullyAllocated_nothingExtractable() public {
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        uw.allocate(address(tranche0), _idle());
        assertEq(_idle(), 0);
        uint256 loss = _slashViaLiquidation();
        assertGt(loss, 0);
        assertGt(uw.totalAssets(), _idle() + tranche0.previewRedeem(tranche0.balanceOf(address(uw))), "mark is stale");
        assertEq(uw.maxRedeem(alice), 0, "instant exit is capped by idle = 0");
        assertEq(uw.maxWithdraw(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        uw.redeem(1, alice, alice);
        // queued exit is also capped by idle
        uint256 aliceBal = uw.balanceOf(alice);
        vm.prank(alice);
        uint256 req = uw.requestRedeem(aliceBal, alice, alice);
        assertEq(uw.claimableRedeemRequest(req, alice), 0, "nothing claimable while idle is zero");
    }

    /// (b) partial idle: total over-payment across every exiter <= idle * L / A_stale
    function test_boundIsIdleTimesLossFraction() public {
        _fundUnderwriter(address(uw), alice, 400e18);
        _fundUnderwriter(address(uw), bob, 400e18);
        _fundUnderwriter(address(uw), carol, 200e18);
        uw.allocate(address(tranche0), 800e18); // idle = 200 of 1000
        uint256 loss = _slashViaLiquidation();
        uint256 idle = _idle();
        uint256 staleA = uw.totalAssets();
        uint256 trueA = idle + tranche0.previewRedeem(tranche0.balanceOf(address(uw)));
        assertApproxEqAbs(staleA - trueA, loss, 1e6, "the whole slash is unrecognised");
        uint256 supply = uw.totalSupply();

        // alice tries to take her whole position: capped at what idle buys at the stale price
        uint256 aliceMax = uw.maxRedeem(alice);
        assertLt(aliceMax, uw.balanceOf(alice), "alice cannot take her full position");
        vm.prank(alice);
        uint256 alicePaid = uw.redeem(aliceMax, alice, alice);
        assertApproxEqAbs(alicePaid, idle, 2, "alice drains the idle exactly");
        uint256 aliceFair = aliceMax * trueA / supply;
        uint256 aliceOver = alicePaid - aliceFair;
        uint256 bound = idle * loss / staleA;
        emit log_named_uint("idle", idle);
        emit log_named_uint("unrecognised loss L", loss);
        emit log_named_uint("alice over-paid", aliceOver);
        emit log_named_uint("bound idle*L/A", bound);
        assertLe(aliceOver, bound + 2, "over-payment bounded by idle * L / A");

        // after idle is gone, bob and carol cannot follow
        assertEq(uw.maxRedeem(bob), 0);
        assertEq(uw.maxRedeem(carol), 0);

        uw.report(address(tranche0));
        // remaining holders share the loss + alice's over-payment
        uint256 bobAfter = uw.previewRedeem(uw.balanceOf(bob));
        uint256 bobFair = uw.balanceOf(bob) * trueA / supply;
        emit log_named_uint("bob fair", bobFair);
        emit log_named_uint("bob after report", bobAfter);
        assertLt(bobAfter, bobFair, "bob absorbs part of alice's over-payment");
    }

    /// (a) with a default tranche set, any admitted depositor can re-mark it with a dust deposit,
    /// which closes the window without the KEEPER. Only covers the default tranche.
    function test_dustDepositReMarksDefaultTranche() public {
        uw.setDefaultTranche(address(tranche0));
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        assertEq(_idle(), 0, "deposits went straight in");
        // curator frees a buffer; deallocate marks fresh at this point
        uw.deallocate(address(tranche0), tranche0.balanceOf(address(uw)) / 2);
        uint256 idle = _idle();
        assertGt(idle, 0);

        uint256 loss = _slashViaLiquidation();
        uint256 trueA = _idle() + tranche0.previewRedeem(tranche0.balanceOf(address(uw)));
        assertGt(uw.totalAssets(), trueA, "stale after slash even in the default-tranche config");

        // bob (an admitted depositor) deposits 1 wei: _transferIn -> _allocate(default) -> _mark
        _fundVault(bob, 1);
        vm.prank(bob);
        uw.deposit(1, bob);
        assertApproxEqAbs(uw.totalAssets(), trueA + 1, 2, "a dust deposit refreshes the mark");
        assertGt(loss, 0);

        // and now alice is paid fairly
        uint256 supply = uw.totalSupply();
        uint256 aliceMax = uw.maxRedeem(alice);
        uint256 fair = aliceMax * uw.totalAssets() / supply;
        vm.prank(alice);
        uint256 paid = uw.redeem(aliceMax, alice, alice);
        assertApproxEqAbs(paid, fair, 2, "paid at the live price");
    }

    /// (c) the exit is not gated by the depositor role: a transferee who was never admitted can
    /// redeem at the stale mark
    function test_transfereeWithoutDepositorRoleRedeemsAtStaleMark() public {
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        uw.allocate(address(tranche0), 500e18);
        assertFalse(_mayDeposit(address(uw), outsider), "outsider is not admitted");
        uint256 aliceBal = uw.balanceOf(alice);
        vm.prank(alice);
        uw.transfer(outsider, aliceBal);

        uint256 loss = _slashViaLiquidation();
        assertGt(loss, 0);
        uint256 trueA = _idle() + tranche0.previewRedeem(tranche0.balanceOf(address(uw)));
        uint256 fair = uw.balanceOf(outsider) * trueA / uw.totalSupply();
        uint256 outMax = uw.maxRedeem(outsider);
        vm.prank(outsider);
        uint256 paid = uw.redeem(outMax, outsider, outsider);
        emit log_named_uint("outsider fair", fair);
        emit log_named_uint("outsider paid", paid);
        assertGt(paid, fair, "un-admitted holder exits at the stale mark");
    }

    /// (a) curator can refresh a non-default tranche with a zero-share deallocate; KEEPER not needed
    function test_curatorZeroDeallocateReMarks() public {
        _fundUnderwriter(address(uw), alice, 500e18);
        _fundUnderwriter(address(uw), bob, 500e18);
        uw.allocate(address(tranche0), 500e18);
        _slashViaLiquidation();
        uint256 trueA = _idle() + tranche0.previewRedeem(tranche0.balanceOf(address(uw)));
        assertGt(uw.totalAssets(), trueA);
        uw.deallocate(address(tranche0), 0);
        assertEq(uw.totalAssets(), trueA, "deallocate(t, 0) re-marks");
    }
}
