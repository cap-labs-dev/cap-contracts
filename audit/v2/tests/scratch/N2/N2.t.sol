// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { IStablecoin } from "../../../../../contracts/interfaces/IStablecoin.sol";
import { BaseTest } from "../../../../../test/shared/BaseTest.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { MockIRM } from "../../../../../test/shared/mocks/MockIRM.sol";
import { LossyAeraVault } from "./LossyAeraVault.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title N2 PoCs: invested reserve vs ERC-4626/7540 promises
contract N2Test is BaseTest {
    Stablecoin internal sc;
    MockERC20 internal asset;
    MockIRM internal irm;
    LossyAeraVault internal aera;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal borrower = makeAddr("borrower");

    function setUp() public {
        _setUpAccessManager();
        asset = new MockERC20("USD Coin", "USDC", 18);
        irm = new MockIRM();
        aera = new LossyAeraVault();
        sc = _deploy(address(aera));
        for (uint256 i; i < 2; ++i) {
            address a = i == 0 ? alice : bob;
            asset.mint(a, 1_000e18);
            vm.prank(a);
            asset.approve(address(sc), type(uint256).max);
        }
    }

    function _deploy(address reserve) internal returns (Stablecoin s) {
        Stablecoin impl = new Stablecoin();
        s = Stablecoin(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(asset), "Cap USD", "cUSD", "", address(irm), reserve)
                )
            )
        );
    }

    function _dep(address who, uint256 amt) internal {
        vm.prank(who);
        sc.deposit(amt, who);
    }

    // ---------------------------------------------------------------- N2a: ERC-4626 lie / DoS

    function test_N2a_maxRedeemUnchangedButRedeemRevertsAfterInvest() public {
        _dep(alice, 1_000e18);
        assertEq(asset.balanceOf(address(sc)), sc.unlockedSupply(), "round-1 identity holds pre-invest");

        sc.invest(600e18);
        assertEq(asset.balanceOf(address(sc)), 400e18);
        assertEq(sc.maxRedeem(alice), 1_000e18, "maxRedeem lies: still 1000");
        assertEq(sc.maxWithdraw(alice), 1_000e18, "maxWithdraw lies: still 1000");
        assertEq(sc.unlockedSupply(), 1_000e18, "identity broken: unlocked 1000 vs balance 400");

        // no partial fill: anything above the liquid balance reverts atomically
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(sc), 400e18, 401e18)
        );
        sc.redeem(401e18, alice, alice);

        vm.prank(alice);
        sc.redeem(400e18, alice, alice);
        assertEq(asset.balanceOf(address(sc)), 0);
        assertEq(sc.maxRedeem(alice), 600e18, "maxRedeem still advertises 600 with 0 liquid");

        vm.prank(alice);
        vm.expectRevert();
        sc.redeem(1, alice, alice);

        // recall repairs it
        sc.recall(600e18);
        vm.prank(alice);
        sc.redeem(600e18, alice, alice);
        assertEq(asset.balanceOf(alice), 1_000e18);
    }

    /// @dev Keeper invests right before a settled queued claim: claimableRedeemRequest says fully
    /// claimable, claim reverts. Redeemer is stuck until a discretionary recall.
    function test_N2a_queuedClaimGriefedByInvest() public {
        _dep(alice, 1_000e18);
        vm.prank(alice);
        uint256 id = sc.requestRedeem(1_000e18, alice, alice);
        assertEq(sc.claimableRedeemRequest(id, alice), 1_000e18, "settled: fully claimable");

        sc.invest(1e18); // 0.1% of reserve is enough to block a full claim
        assertEq(sc.claimableRedeemRequest(id, alice), 1_000e18, "still says claimable");

        vm.prank(alice);
        vm.expectRevert();
        sc.redeem(id, 1_000e18, alice, alice);

        // partial claim up to liquid balance works, remainder waits on recall
        vm.prank(alice);
        sc.redeem(id, 999e18, alice, alice);
        vm.prank(alice);
        vm.expectRevert();
        sc.redeem(id, 1e18, alice, alice);
    }

    // ---------------------------------------------------------------- N2b: loss not recognised

    /// @dev Two depositors 500 each; 50% of the reserve invested; Aera loses 20% of it (100).
    /// Alice exits at par; Bob is told maxRedeem = 500 but only 400 exists. badDebt stays 0,
    /// totalAssets still reports 1000 backing while the system holds 900.
    function test_N2b_aeraLossLandsOnLastRedeemer() public {
        _dep(alice, 500e18);
        _dep(bob, 500e18);
        sc.invest(500e18);
        uint256 lost = aera.lose(IERC20(address(asset)), 2_000);
        assertEq(lost, 100e18);
        sc.recall(400e18); // everything Aera still has

        assertEq(asset.balanceOf(address(sc)) + asset.balanceOf(address(aera)), 900e18, "system holds 900");
        assertEq(sc.unlockedSupply(), 1_000e18, "unlockedSupply says 1000");
        assertEq(sc.totalAssets(), 1_000e18, "totalAssets says 1000 (no haircut)");
        assertEq(sc.badDebt(), 0, "loss never booked");
        assertEq(sc.previewRedeem(1e18), 1e18, "share price still par");

        // first out: par
        vm.prank(alice);
        sc.redeem(500e18, alice, alice);
        assertEq(asset.balanceOf(alice), 1_000e18);

        // last out: advertised 500, gets at most 400, 100 cUSD permanently unbacked
        assertEq(sc.maxRedeem(bob), 500e18);
        vm.prank(bob);
        vm.expectRevert();
        sc.redeem(500e18, bob, bob);
        vm.prank(bob);
        sc.redeem(400e18, bob, bob);
        assertEq(sc.balanceOf(bob), 100e18, "bob holds 100 cUSD with zero backing");
        assertEq(asset.balanceOf(address(sc)), 0);
        assertEq(sc.totalAssets(), 100e18, "still reports 100 of backing");
    }

    /// @dev No path exists to book an investment loss: recognizeBadDebt needs creditBackedSupply,
    /// coverBadDebt needs badDebt > 0.
    function test_N2b_noRecognitionPath() public {
        _dep(alice, 500e18);
        sc.invest(500e18);
        aera.lose(IERC20(address(asset)), 2_000);
        assertEq(sc.creditBackedSupply(), 0);

        vm.expectRevert(); // creditBackedSupply -= 100 underflows
        sc.recognizeBadDebt(100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStablecoin.NoBadDebt.selector));
        sc.coverBadDebt(100e18);

        // even with outstanding credit, recognizeBadDebt mislabels the reserve loss as a
        // borrower write-off: it lowers creditBackedSupply (and utilization) for a loss that
        // has nothing to do with credit, so a market could not honestly call it either
        sc.mintCreditBacked(borrower, 200e18);
        sc.recognizeBadDebt(100e18);
        assertEq(sc.creditBackedSupply(), 100e18, "credit accounting corrupted to book a reserve loss");
    }

    // ---------------------------------------------------------------- N2c: reserveVault config

    function test_N2c_investAndRecallRevertWithZeroReserveVault() public {
        Stablecoin z = _deploy(address(0));
        vm.startPrank(alice);
        asset.approve(address(z), type(uint256).max);
        z.deposit(100e18, alice);
        vm.stopPrank();
        assertEq(z.reserveVault(), address(0));
        vm.expectRevert(); // forceApprove(address(0)) -> ERC20InvalidSpender on OZ ERC20
        z.invest(1e18);
        vm.expectRevert(); // call to address(0) with no code
        z.recall(1e18);
        // no setter exists: selector absent from the ABI
        (bool ok,) = address(z).call(abi.encodeWithSignature("setReserveVault(address)", address(aera)));
        assertFalse(ok, "no setter");
    }

    function test_N2c_recallRevertsWhenAeraRefuses_reserveStuck() public {
        _dep(alice, 1_000e18);
        sc.invest(1_000e18);
        aera.setRefuse(true);
        vm.expectRevert(abi.encodeWithSelector(LossyAeraVault.Aera__Refused.selector));
        sc.recall(1e18);
        // every redemption is now dead while the 4626 surface says otherwise
        assertEq(sc.maxRedeem(alice), 1_000e18);
        vm.prank(alice);
        vm.expectRevert();
        sc.redeem(1, alice, alice);
    }

    // ---------------------------------------------------------------- N2d: allowance hygiene

    function test_N2d_noLeftoverAllowanceAfterInvest() public {
        _dep(alice, 1_000e18);
        sc.invest(250e18);
        assertEq(asset.allowance(address(sc), address(aera)), 0, "allowance fully consumed");
        // a second invest re-approves from zero; forceApprove handles non-zero->non-zero too
        sc.invest(250e18);
        assertEq(asset.allowance(address(sc), address(aera)), 0);
        assertEq(asset.balanceOf(address(aera)), 500e18);
    }

    // ---------------------------------------------------------------- N2e: public fund / coverBadDebt

    function test_N2e_fundByOutsiderLowersUtilization() public {
        _dep(alice, 1_000e18);
        sc.mintCreditBacked(borrower, 800e18); // 800 / 1800 utilization
        uint256 before = sc.utilizationRate();
        vm.prank(bob);
        sc.fund(1_000e18); // anyone; mints supply to the pot at par
        assertLt(sc.utilizationRate(), before, "utilization falls (borrow rate down) for the cost of a donation");
        // nothing is stolen: the outsider's 1000 backs 1000 pot shares that vest to holders
        assertEq(asset.balanceOf(address(sc)), sc.unlockedSupply());
    }

    function test_N2e_coverBadDebtFrontRunIsBenign() public {
        _dep(alice, 500e18);
        _dep(bob, 500e18);
        sc.mintCreditBacked(borrower, 100e18);
        sc.recognizeBadDebt(100e18);
        // bob front-runs alice's cover with a full cover
        vm.prank(bob);
        assertEq(sc.coverBadDebt(100e18), 100e18);
        // alice's tx now reverts rather than double-burning
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStablecoin.NoBadDebt.selector));
        sc.coverBadDebt(100e18);
        assertEq(sc.badDebt(), 0);
        assertEq(sc.balanceOf(bob), 400e18);
        assertEq(sc.balanceOf(alice), 500e18);
        assertEq(asset.balanceOf(address(sc)), sc.unlockedSupply());
        // coverBadDebt(0) while badDebt > 0 is a no-op burn (event spam only)
        sc.mintCreditBacked(borrower, 1e18);
        sc.recognizeBadDebt(1e18);
        vm.prank(alice);
        assertEq(sc.coverBadDebt(0), 0);
    }
}
