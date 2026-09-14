// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../contracts/cap/Stablecoin.sol";
import { IStablecoin } from "../../../../contracts/interfaces/IStablecoin.sol";
import { CapRoles } from "../../../../contracts/utils/CapRoles.sol";
import { BaseTest } from "../../../../test/shared/BaseTest.sol";
import { MockAeraVault } from "../../../../test/shared/mocks/MockAeraVault.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";
import { MockIRM } from "../../../../test/shared/mocks/MockIRM.sol";

/// @notice Killing tests for the Stablecoin's reserve and bad-debt guards. Same harness as
/// `test/unit/cap/Stablecoin.t.sol` (MockIRM, MockAeraVault, 18-dec underlying).
///
/// - Gambit `Stablecoin#107` (== hand mutant H10) drops the on-hand cap in
///   {Stablecoin-unlockedSupply}. With reserve parked in Aera the vault then reports unlocked
///   supply it cannot pay (I1), `maxRedeem`/`maxInstantRedeem` over-quote, and the FIFO watermark
///   advances past the cash on hand. The stock test (`Stablecoin.t.sol:963-980`) only expects the
///   eventual `instantRedeem` to revert, with no selector, which the failed transfer satisfies.
/// - Gambit `Stablecoin#64` (== H21) drops `badDebt > totalSupply()` in
///   {Stablecoin-recognizeBadDebtInCredit}. The credit path alone cannot breach it (it moves credit
///   into bad debt), but after {recognizeBadDebtInReserve} has raised bad debt the credit path
///   can push it past supply and the shortfall curve past one (I2/I35).
/// - Gambit `Stablecoin#303` drops the `reduced > badDebt` clamp in {Stablecoin-_onWithdraw}; the
///   last test is evidence that the clamp is unreachable (not a kill).
/// - Gambit `Stablecoin#86` drops the `updateLiquidityRate` hook in {Stablecoin-coverBadDebt}.
contract StablecoinGuardsKillTest is BaseTest {
    Stablecoin internal scoin;
    MockERC20 internal asset;
    MockIRM internal irm;
    MockAeraVault internal reserve;

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal sink = makeAddr("defaultedBorrower");

    function setUp() public {
        _setUpAccessManager();
        asset = new MockERC20("USD Coin", "USDC", 18);
        irm = new MockIRM();
        reserve = new MockAeraVault();

        Stablecoin impl = new Stablecoin();
        scoin = Stablecoin(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(asset), "Cap USD", "cUSD", address(irm), address(reserve))
                )
            )
        );

        asset.mint(alice, 1_000e18);
        vm.prank(alice);
        asset.approve(address(scoin), type(uint256).max);

        bytes4[] memory keeperSelectors = new bytes4[](2);
        keeperSelectors[0] = Stablecoin.invest.selector;
        keeperSelectors[1] = Stablecoin.recall.selector;
        _grantRoleForTarget(CapRoles.KEEPER, keeper, address(scoin), keeperSelectors);

        bytes4[] memory guardianSelectors = new bytes4[](1);
        guardianSelectors[0] = Stablecoin.recognizeBadDebtInReserve.selector;
        _grantRoleForTarget(CapRoles.GUARDIAN, guardian, address(scoin), guardianSelectors);
    }

    /// Kills Stablecoin#107 / H10: parked reserve is not redeemable until recalled, and every
    /// view says so.
    function test_unlockedSupplyIsCappedByTheReserveOnHand() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        assertEq(scoin.unlockedSupply(), 1_000e18);

        vm.prank(keeper);
        scoin.invest(400e18);

        assertEq(asset.balanceOf(address(scoin)), 600e18);
        assertEq(scoin.unlockedSupply(), 600e18, "only the cash on hand is unlocked (I1)");
        assertEq(scoin.maxInstantRedeem(alice), 600e18, "instant quote is capped");
        assertEq(scoin.maxInstantWithdraw(alice), 600e18);

        vm.prank(alice);
        uint256 id = scoin.requestRedeem(1_000e18, alice, alice);
        assertEq(scoin.claimableRedeemRequest(id, alice), 600e18, "the watermark stops at the cash");
        assertEq(scoin.pendingRedeemRequest(id, alice), 400e18);
        assertEq(scoin.maxRedeem(alice), 600e18);

        vm.prank(keeper);
        scoin.recall(400e18);
        assertEq(scoin.unlockedSupply(), 1_000e18, "recalled reserve unlocks again");
        assertEq(scoin.claimableRedeemRequest(id, alice), 1_000e18);
    }

    /// Kills Stablecoin#64 / H21: bad debt can never be recognised past total supply.
    function test_badDebtInCreditCannotExceedSupply() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.mintCreditBacked(sink, 100e18);
        assertEq(scoin.totalSupply(), 200e18);

        vm.prank(guardian);
        scoin.recognizeBadDebtInReserve(150e18);
        assertEq(scoin.badDebt(), 150e18);

        vm.expectRevert(IStablecoin.BadDebtExceedsSupply.selector);
        scoin.recognizeBadDebtInCredit(60e18);

        assertEq(scoin.badDebt(), 150e18, "nothing recognised");
        assertEq(scoin.creditBackedSupply(), 100e18, "nothing moved out of credit");
        assertLe(scoin.badDebt(), scoin.totalSupply(), "I35");

        scoin.recognizeBadDebtInCredit(50e18);
        assertEq(scoin.badDebt(), 200e18, "exactly the supply is the ceiling");
    }

    /// Evidence for Stablecoin#303 (the `reduced > badDebt` clamp in {_onWithdraw}), which this
    /// test does NOT kill: every exit's haircut `_shares - paidInShares` is floored below its
    /// pro-rata share of the recognised bad debt, so the sum of haircuts never reaches `badDebt`
    /// and the clamp is unreachable. What the suite can pin is that retirement is monotone,
    /// never reverts, and strands only dust once every holder has left.
    function test_badDebtRetirementIsMonotoneAndStrandsOnlyDust() public {
        vm.prank(alice);
        scoin.deposit(1_000e18, alice);
        scoin.mintCreditBacked(sink, 7e18);
        scoin.recognizeBadDebtInCredit(7e18);
        assertEq(scoin.badDebt(), 7e18);

        // walk the whole supply out through many small exits so the per-exit floors accumulate
        uint256 last = scoin.badDebt();
        vm.startPrank(alice);
        for (uint256 i; i < 40; ++i) {
            scoin.instantRedeem(25e18 - 1, alice, alice);
            assertLe(scoin.badDebt(), last, "bad debt only falls");
            last = scoin.badDebt();
        }
        vm.stopPrank();
        uint256 sinkMax = scoin.maxInstantRedeem(sink);
        vm.prank(sink);
        scoin.instantRedeem(sinkMax, sink, sink);

        assertLe(scoin.badDebt(), last, "bad debt only falls");
        assertLt(scoin.badDebt(), 1e12, "what is left un-retired is dust (806409 wei at HEAD)");
        assertLe(scoin.badDebt(), scoin.totalSupply(), "I35");
    }

    /// Kills Stablecoin#86: covering bad debt burns supply, so the rate model must be told.
    function test_coverBadDebtRefreshesTheLiquidityRate() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.mintCreditBacked(alice, 50e18);
        scoin.recognizeBadDebtInCredit(50e18);

        uint256 calls = irm.updateCalls();
        vm.prank(alice);
        uint256 covered = scoin.coverBadDebt(20e18);

        assertEq(covered, 20e18);
        assertEq(scoin.badDebt(), 30e18);
        assertEq(irm.updateCalls(), calls + 1, "the burn is reported to the rate model");
    }
}
