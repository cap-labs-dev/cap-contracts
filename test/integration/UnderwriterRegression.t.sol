// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Live issuance marks, retirement, and executable idle-cash limits.
contract UnderwriterRegressionTest is CapDeployer {
    Underwriter internal pool;
    Tranche internal tranche;
    FloatingMarket internal market;
    address internal incumbent = makeAddr("incumbent");
    address internal entrant = makeAddr("entrant");

    function setUp() public {
        _deployCap();
        (address m, address t,) = _createMarket("Underwriter regressions");
        market = FloatingMarket(m);
        tranche = Tranche(t);
        // Seed independently so the pool's subsequent allocation pays no new seed cost.
        _fundTranche(t, makeAddr("seed supplier"), DEAD_SHARES + 1);
        pool = _deployUnderwriter();
        pool.addTranche(t);
        _admitDepositor(t, address(pool));
    }

    function _allocateAll(uint256 amount) internal {
        pool.setDefaultTranche(address(tranche));
        _fundUnderwriter(address(pool), incumbent, amount);
    }

    function _slash(uint256 amount) internal {
        vm.prank(address(market));
        tranche.slash(amount, makeAddr("liquidator recipient"));
    }

    function _prepareEntrant(uint256 assets) internal {
        _fundVault(entrant, assets);
        _admitDepositor(address(pool), entrant);
        vm.prank(entrant);
        vault.setOperator(address(pool), true);
    }

    /// @dev Both issue paths must price gains and losses before allocation persists the mark.
    function testFuzz_issuanceUsesLiveDefaultIncludingQueuedShares(
        uint96 rawChange,
        bool gain,
        bool mintShares,
        bool queue
    ) public {
        _allocateAll(1_000e18);
        if (queue) pool.deallocateAsync(address(tranche), 300e18);
        uint256 change = bound(rawChange, 1e18, 400e18);
        if (gain) _fundVault(address(tranche), change);
        else _slash(change);

        uint256 recorded = pool.debt(address(tranche));
        uint256 live = tranche.convertToAssets(tranche.balanceOf(address(pool)) + pool.queuedShares(address(tranche)));
        uint256 supply = pool.totalSupply();
        uint256 incumbentBefore = Math.mulDiv(pool.balanceOf(incumbent), live + 1, supply + 1);
        uint256 amount = 100e18;
        uint256 quote = mintShares ? pool.previewMint(amount) : pool.previewDeposit(amount);
        assertEq(pool.debt(address(tranche)), recorded, "preview must not persist a mark");
        assertEq(pool.totalAssets(), recorded, "totalAssets retains the cached book");
        assertTrue(live != recorded, "exercise a stale book");
        if (mintShares) assertEq(quote, Math.mulDiv(amount, live + 1, supply + 1, Math.Rounding.Ceil));
        else assertEq(quote, Math.mulDiv(amount, supply + 1, live + 1));

        _prepareEntrant(mintShares ? quote : amount);
        vm.prank(entrant);
        uint256 result = mintShares ? pool.mint(amount, entrant) : pool.deposit(amount, entrant);
        assertEq(result, quote, "execution matches the view quote");
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(incumbent)), incumbentBefore, 3);
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(entrant)), mintShares ? quote : amount, 3);
        assertEq(
            pool.debt(address(tranche)),
            tranche.convertToAssets(tranche.balanceOf(address(pool)) + pool.queuedShares(address(tranche)))
        );
    }

    function test_issuanceIncludesAZeroBookDefaultPosition() public {
        _fundUnderwriter(address(pool), incumbent, 1_000e18);
        address donor = makeAddr("position donor");
        _fundTranche(address(tranche), donor, 500e18);
        vm.prank(donor);
        tranche.transfer(address(pool), 500e18);
        pool.setDefaultTranche(address(tranche));
        assertEq(pool.debt(address(tranche)), 0);
        uint256 quote = pool.previewDeposit(1_000e18);
        assertLt(quote, 700e18, "the unrecorded position belongs to incumbent shares");
        _prepareEntrant(1_000e18);
        vm.prank(entrant);
        assertEq(pool.deposit(1_000e18, entrant), quote);
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(entrant)), 1_000e18, 3);
        assertApproxEqAbs(pool.convertToAssets(pool.balanceOf(incumbent)), 1_500e18, 2_000);
    }

    function test_zeroMarkedRecoveryIsQuotedButKilledDefaultStillBlocksDeposits() public {
        _fundUnderwriter(address(pool), incumbent, 1_000e18);
        pool.allocate(address(tranche), 500e18);
        pool.setDefaultTranche(address(tranche));
        _slash(tranche.totalAssets());
        pool.report(address(tranche));
        assertEq(pool.debt(address(tranche)), 0);
        assertFalse(pool.killed(), "the idle half survived");
        _fundVault(address(tranche), 500e18);
        uint256 live = tranche.convertToAssets(tranche.balanceOf(address(pool)));
        assertGt(live, 499e18);
        assertEq(pool.previewDeposit(100e18), Math.mulDiv(100e18, pool.totalSupply() + 1, 500e18 + live + 1));
        assertEq(pool.debt(address(tranche)), 0, "view pricing does not reopen the recorded book");
        assertEq(pool.maxDeposit(entrant), 0, "the retired default must be replaced before deposits resume");
    }

    function test_nonDefaultMarkStaysCachedUntilReported() public {
        _fundUnderwriter(address(pool), incumbent, 1_000e18);
        pool.allocate(address(tranche), 800e18);
        uint256 quote = pool.previewDeposit(100e18);
        _slash(200e18);
        assertEq(pool.previewDeposit(100e18), quote, "only the default position gets a live issuance mark");
        pool.report(address(tranche));
        assertGt(pool.previewDeposit(100e18), quote);
    }

    function test_defaultQuoteFailurePropagatesWithoutChangingTheBook() public {
        _allocateAll(1_000e18);
        vm.mockCallRevert(address(tranche), abi.encodeWithSelector(tranche.convertToAssets.selector), "quote failed");
        vm.expectRevert(bytes("quote failed"));
        pool.previewDeposit(100e18);
        vm.expectRevert(bytes("quote failed"));
        pool.previewMint(100e18);
        assertEq(pool.totalAssets(), 1_000e18);
    }

    function test_fullLossRetiresPoolAndRecoveryCannotReopenIt() public {
        _allocateAll(1_000e18);
        _slash(tranche.totalAssets());
        pool.report(address(tranche));
        assertTrue(pool.killed());
        assertEq(pool.totalAssets(), 0);
        _fundVault(address(pool), 2_000e18);
        pool.removeTranche(address(tranche));
        assertTrue(pool.killed(), "retirement is permanent after recapitalization");
        _assertDepositsClosed();
    }

    function test_liquidationLossRetiresPoolWhenReported() public {
        _allocateAll(1_000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
        _setPrice(address(collateral), 0.1e18);
        _mintStable(defaultLiquidator, 400e18);
        vm.prank(defaultLiquidator);
        (, uint256 slashed) = market.liquidate(defaultLiquidator, type(uint256).max);
        assertGt(slashed, 99e18);
        assertTrue(tranche.killed());
        assertFalse(pool.killed(), "the pool still has its old recorded mark");
        pool.report(address(tranche));
        assertTrue(pool.killed());
        _assertDepositsClosed();
    }

    function test_reportingAClosedBookStillLatchesRetirementAfterAnExit() public {
        _fundUnderwriter(address(pool), incumbent, 1_000_000);
        pool.allocate(address(tranche), 1_000_000);
        _slash(tranche.totalAssets() - 10_010);
        pool.report(address(tranche));
        pool.deallocate(address(tranche), tranche.balanceOf(address(pool)));
        assertEq(pool.totalAssets(), 10_000);
        assertEq(pool.debt(address(tranche)), 0);
        assertFalse(pool.killed());
        vm.prank(incumbent);
        assertEq(pool.instantRedeem(20_099, incumbent, incumbent), 201);
        assertFalse(pool.killed(), "underwriter retirement is latched on a marking operation");
        assertEq(pool.maxDeposit(entrant), 0, "the live threshold closes deposits immediately");
        pool.report(address(tranche));
        assertTrue(pool.killed(), "even a zero book must execute the retirement check");
    }

    function test_onePercentIsOpenAndOneAssetLessRetiresPool() public {
        _fundUnderwriter(address(pool), incumbent, 10_000);
        pool.allocate(address(tranche), 10_000);
        // The pool holds 10,000 of 11,001 tranche shares; 110 assets quote to 100.
        _slash(tranche.totalAssets() - 110);
        pool.report(address(tranche));
        assertEq(pool.totalAssets(), 100);
        assertFalse(pool.killed());
        assertEq(pool.maxDeposit(entrant), type(uint256).max);
        _slash(1);
        pool.report(address(tranche));
        assertEq(pool.totalAssets(), 99);
        assertTrue(pool.killed());
        _assertDepositsClosed();
    }

    function test_killedDefaultClosesLimitsWithoutRetiringHealthyPool() public {
        _fundUnderwriter(address(pool), incumbent, 1_000e18);
        pool.allocate(address(tranche), 10e18);
        pool.setDefaultTranche(address(tranche));
        _slash(tranche.totalAssets());
        pool.report(address(tranche));
        assertFalse(pool.killed(), "idle assets keep the pool healthy");
        _assertDepositsClosed();
        pool.removeTranche(address(tranche));
        assertEq(pool.maxDeposit(entrant), type(uint256).max);
        assertEq(pool.maxMint(entrant), type(uint256).max);
        _fundUnderwriter(address(pool), entrant, 100e18);
    }

    function test_emptyAndUnchangedZeroBookDoNotKillAnUnfundedPool() public {
        pool.report(address(tranche));
        assertFalse(pool.killed());
        assertEq(pool.maxDeposit(entrant), type(uint256).max);
        assertEq(pool.maxMint(entrant), type(uint256).max);
    }

    function test_retiredPoolStillPaysPremiumAndAllowsAnExit() public {
        _allocateAll(1_000e18);
        stablecoin.mintCreditBacked(address(tranche), 10e18);
        vm.prank(address(market));
        tranche.fund(10e18);
        vm.warp(block.timestamp + 20 * tranche.vestingPeriod());
        _slash(tranche.totalAssets() - 1e18);
        pool.report(address(tranche));
        assertTrue(pool.killed());
        vm.warp(block.timestamp + 20 * pool.vestingPeriod());
        vm.prank(incumbent);
        assertGt(pool.claim(incumbent), 9e18);
        pool.deallocate(address(tranche), tranche.balanceOf(address(pool)));
        uint256 shares = pool.maxInstantRedeem(incumbent);
        vm.prank(incumbent);
        assertGt(pool.instantRedeem(shares, incumbent, incumbent), 0);
        assertTrue(pool.killed());
    }

    function test_allocationThatRetiresPoolRollsBackTheIncomingDeposit() public {
        address fresh = market.tranches()[1].tranche;
        pool.addTranche(fresh);
        _admitDepositor(fresh, address(pool));
        pool.setDefaultTranche(fresh);
        _prepareEntrant(DEAD_SHARES + 1);
        assertEq(pool.previewDeposit(DEAD_SHARES + 1), 1);
        vm.prank(entrant);
        vm.expectRevert(IUnderwriter.UnderwriterKilled.selector);
        pool.deposit(DEAD_SHARES + 1, entrant);
        assertEq(vault.balanceOf(entrant, address(collateral)), DEAD_SHARES + 1);
        assertEq(pool.totalSupply(), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(Tranche(fresh).totalSupply(), 0, "the nested seed mint is rolled back too");
        assertFalse(pool.killed());
    }

    function _assertDepositsClosed() internal {
        assertEq(pool.maxDeposit(entrant), 0);
        assertEq(pool.maxMint(entrant), 0);
        _prepareEntrant(100e18);
        vm.startPrank(entrant);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, entrant, 1, 0));
        pool.deposit(1, entrant);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, entrant, 1, 0));
        pool.mint(1, entrant);
        vm.stopPrank();
    }

    function _roundingState() internal {
        _fundUnderwriter(address(pool), incumbent, 2_000);
        pool.allocate(address(tranche), 1_904);
        _fundVault(address(tranche), 33);
        pool.report(address(tranche));
        assertEq(pool.totalSupply(), 2_000);
        assertEq(pool.totalAssets(), 2_021);
        assertEq(vault.balanceOf(address(pool), address(collateral)), 96);
        assertEq(pool.unlockedSupply(), 95);
        assertEq(pool.convertToAssets(96), 97, "old ceil limit was not payable");
    }

    function test_advertisedInstantRedeemPaysFromIdleAssets() public {
        _roundingState();
        uint256 shares = pool.maxInstantRedeem(incumbent);
        assertEq(shares, 95);
        vm.prank(incumbent);
        assertEq(pool.instantRedeem(shares, incumbent, incumbent), 95);
        assertEq(vault.balanceOf(address(pool), address(collateral)), 1);
    }

    function test_advertisedQueuedRedeemPaysFromIdleAssets() public {
        _roundingState();
        vm.prank(incumbent);
        uint256 id = pool.requestRedeem(200, incumbent, incumbent);
        assertEq(pool.claimableRedeemRequest(id, incumbent), 95);
        assertEq(pool.maxRedeem(incumbent), 95);
        assertEq(pool.maxInstantRedeem(incumbent), 0, "queued shares reserve the idle cash");
        vm.prank(incumbent);
        assertEq(pool.redeem(id, 95, incumbent, incumbent), 95);
        assertEq(pool.pendingRedeemRequest(id, incumbent), 105);
    }

    function test_exactAssetWithdrawalStillRoundsSharesUp() public {
        _roundingState();
        vm.prank(incumbent);
        assertEq(pool.instantWithdraw(95, incumbent, incumbent), 95, "94 floored shares would pay only 94 assets");
        assertEq(vault.balanceOf(address(pool), address(collateral)), 1);
    }

    function testFuzz_advertisedRedeemNeverExceedsIdleAssets(uint96 rawIdle, uint96 rawGain) public {
        _fundUnderwriter(address(pool), incumbent, 1_000e18);
        uint256 idle = bound(rawIdle, 1, 500e18);
        pool.allocate(address(tranche), 1_000e18 - idle);
        _fundVault(address(tranche), bound(rawGain, 0, 1_000e18));
        pool.report(address(tranche));
        uint256 shares = pool.maxInstantRedeem(incumbent);
        assertLe(pool.convertToAssets(shares), idle);
        vm.prank(incumbent);
        uint256 paid = pool.instantRedeem(shares, incumbent, incumbent);
        assertEq(vault.balanceOf(address(pool), address(collateral)), idle - paid);
    }
}
