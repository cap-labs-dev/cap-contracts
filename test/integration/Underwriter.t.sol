// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

contract UnderwriterIntegrationTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal depositor = makeAddr("depositor");
    FloatingMarket internal market;
    Tranche internal tranche0;
    Tranche internal tranche1;
    Underwriter internal underwriter;

    uint256 internal constant DEPOSIT = 1_000e18;

    function setUp() public {
        _deployCap();

        address marketAddr;
        address t0;
        address t1;
        (marketAddr, t0, t1) = _createMarket("Market A");
        market = FloatingMarket(marketAddr);
        tranche0 = Tranche(t0);
        tranche1 = Tranche(t1);

        _setMarketSlopes(marketAddr);
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        market.setMarketMultiplier(1e27);
        _setMaxCapital(market, 1_000e18);

        underwriter = _deployUnderwriter();
        _admitDepositor(address(tranche0), address(underwriter));
    }

    function _useTranche0AsDefault() internal {
        underwriter.addTranche(address(tranche0));
        underwriter.setDefaultTranche(address(tranche0));
    }

    function test_deposit_allocatesToDefaultTranche() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        assertEq(underwriter.balanceOf(depositor), DEPOSIT - DEAD_SHARES);
        assertEq(tranche0.balanceOf(address(underwriter)), DEPOSIT - DEAD_SHARES);
        assertEq(collateral.balanceOf(address(tranche0)), DEPOSIT);
        assertEq(collateral.balanceOf(address(underwriter)), 0);
        // the dead shares the allocation seeded in the tranche are gone for good
        assertEq(underwriter.totalAssets(), DEPOSIT - DEAD_SHARES);
    }

    function test_manualAllocateDeallocate_roundtrips() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);
        assertEq(collateral.balanceOf(address(underwriter)), DEPOSIT);

        underwriter.addTranche(address(tranche0));
        underwriter.allocate(address(tranche0), DEPOSIT);
        assertEq(tranche0.balanceOf(address(underwriter)), DEPOSIT - DEAD_SHARES);
        assertEq(collateral.balanceOf(address(underwriter)), 0);

        // the underwriter only ever held the allocation less the tranche's seed, so that is all
        // there is to redeem back out of it
        uint256 freed = underwriter.deallocate(address(tranche0), DEPOSIT);
        assertEq(freed, DEPOSIT - DEAD_SHARES);
        assertEq(collateral.balanceOf(address(underwriter)), DEPOSIT - DEAD_SHARES);
    }

    function test_deallocateAsync_clampsToHeldShares() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);
        underwriter.addTranche(address(tranche0));
        underwriter.allocate(address(tranche0), DEPOSIT);

        uint256 held = tranche0.balanceOf(address(underwriter));
        uint256 requestId = underwriter.deallocateAsync(address(tranche0), held + 1e18);

        assertEq(underwriter.queuedShares(address(tranche0)), held, "an oversized request is a short fill");
        assertEq(
            tranche0.claimableRedeemRequest(requestId, address(underwriter))
                + tranche0.pendingRedeemRequest(requestId, address(underwriter)),
            held
        );
        assertEq(tranche0.balanceOf(address(underwriter)), 0);
    }

    function test_curatorControlsTheAllocatorRole() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);
        underwriter.addTranche(address(tranche0));

        uint64 allocatorRole = _allocatorRole(address(underwriter));
        accessManager.revokeRole(allocatorRole, address(this));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        underwriter.allocate(address(tranche0), DEPOSIT);

        address allocator = makeAddr("allocator");
        accessManager.grantRole(allocatorRole, allocator, 0);
        vm.prank(allocator);
        underwriter.allocate(address(tranche0), DEPOSIT);

        assertEq(tranche0.balanceOf(address(underwriter)), DEPOSIT - DEAD_SHARES);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, allocator));
        underwriter.addTranche(address(tranche1));
    }

    function test_deallocate_afterRemoveTranche() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        underwriter.addTranche(address(tranche0));
        underwriter.allocate(address(tranche0), DEPOSIT);
        assertEq(tranche0.balanceOf(address(underwriter)), DEPOSIT - DEAD_SHARES);

        underwriter.removeTranche(address(tranche0));

        vm.expectRevert(IUnderwriter.NotRegisteredTranche.selector);
        underwriter.allocate(address(tranche0), 1e18);

        uint256 freed = underwriter.deallocate(address(tranche0), DEPOSIT);
        assertEq(freed, DEPOSIT - DEAD_SHARES);
        assertEq(collateral.balanceOf(address(underwriter)), DEPOSIT - DEAD_SHARES);
    }

    /// @dev Deregistration deliberately leaves the exits open while closing new allocations, but
    /// every deposit routes through the default tranche and allocation is one of the things it
    /// closes. Left pointing at a removed tranche the default jammed each subsequent deposit, so
    /// retiring a curator's only tranche also stopped the vault taking money.
    function test_removingTheDefaultTrancheDoesNotJamDeposits() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        underwriter.removeTranche(address(tranche0));
        assertEq(underwriter.defaultTranche(), address(0), "the default cannot outlive its registration");

        address latecomer = makeAddr("latecomer");
        _fundUnderwriter(address(underwriter), latecomer, DEPOSIT);

        assertGt(underwriter.balanceOf(latecomer), 0, "the deposit still lands");
        assertEq(
            collateral.balanceOf(address(underwriter)),
            DEPOSIT,
            "and sits idle in the vault, which is what an unset default has always meant"
        );
    }

    /// @dev The underwriter's own shares are user redemption escrow and its cUSD is the premium pot.
    /// Naming either as a tranche would let the allocator burn or re-queue that escrow, or redeem the
    /// pot into an asset nothing can recover.
    function test_exitsRejectTheUnderwriterAndStablecoin() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);
        vm.prank(depositor);
        uint256 requestId = underwriter.requestRedeem(100e18, depositor, depositor);
        uint256 escrow = underwriter.balanceOf(address(underwriter));
        uint256 queue = underwriter.redemptionQueue();
        assertEq(escrow, 100e18);

        address[2] memory targets = [address(underwriter), address(stablecoin)];
        for (uint256 i; i < targets.length; ++i) {
            vm.expectRevert(IUnderwriter.InvalidTranche.selector);
            underwriter.deallocate(targets[i], escrow);
            vm.expectRevert(IUnderwriter.InvalidTranche.selector);
            underwriter.deallocateAsync(targets[i], escrow);
            vm.expectRevert(IUnderwriter.InvalidTranche.selector);
            underwriter.finalizeDeallocateAsync(targets[i], requestId, escrow);
        }

        assertEq(underwriter.balanceOf(address(underwriter)), escrow, "the escrow is untouched");
        assertEq(underwriter.redemptionQueue(), queue, "and queued once");
        vm.prank(depositor);
        assertEq(underwriter.redeem(requestId, 100e18, depositor, depositor), 100e18, "the request still settles");
    }

    function test_addTranche_rejectsTheUnderwriterAndStablecoin() public {
        vm.expectRevert(IUnderwriter.InvalidTranche.selector);
        underwriter.addTranche(address(underwriter));
        vm.expectRevert(IUnderwriter.InvalidTranche.selector);
        underwriter.addTranche(address(stablecoin));
        assertEq(underwriter.registeredTranches().length, 0);
    }

    function test_allocate_nonTranche_reverts() public {
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);
        vm.expectRevert(IUnderwriter.NotRegisteredTranche.selector);
        underwriter.allocate(makeAddr("notTranche"), 1e18);
    }

    /// @dev {removeTranche} used to refuse {report}, so leftover shares kept earning on the
    /// tranche and that later premium sat there until a re-add. Deregistration only closes new
    /// allocations; the remaining position must still be claimable.
    function test_removeTranche_laterPremiumStillClaimableWithoutReAdd() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        market.chargePremium();
        vm.warp(block.timestamp + 20 * underwriter.vestingPeriod());

        underwriter.removeTranche(address(tranche0));
        uint256 pulledOnRemove = stablecoin.balanceOf(address(underwriter));
        assertGt(pulledOnRemove, 0, "remove reports what has already vested");

        vm.warp(block.timestamp + 365 days);
        market.chargePremium();
        vm.warp(block.timestamp + 20 * underwriter.vestingPeriod());

        underwriter.report(address(tranche0));
        assertGt(
            stablecoin.balanceOf(address(underwriter)), pulledOnRemove, "later premium is not stranded until a re-add"
        );
    }

    function test_curatorEarnsPremiumAndDistributesToDepositor() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.warp(block.timestamp + 365 days);
        market.chargePremium();

        vm.warp(block.timestamp + 20 * underwriter.vestingPeriod());

        underwriter.report(address(tranche0));
        uint256 pulled = stablecoin.balanceOf(address(underwriter));
        assertGt(pulled, 0);

        assertEq(stablecoin.balanceOf(depositor), 0);

        vm.warp(block.timestamp + 20 * underwriter.vestingPeriod());
        uint256 claimable = underwriter.claimable(depositor);
        assertGt(claimable, 0);

        vm.prank(depositor);
        underwriter.claim(depositor);

        assertApproxEqAbs(stablecoin.balanceOf(depositor), claimable, 1e6);
        assertLt(stablecoin.balanceOf(address(underwriter)), pulled / 1e6, "only the exponential tail is left");
    }

    function test_asyncRedemption_pendingUntilDeallocated() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        assertEq(underwriter.unlockedSupply(), 0);

        vm.prank(depositor);
        uint256 reqId = underwriter.requestRedeem(DEPOSIT - DEAD_SHARES, depositor, depositor);

        assertEq(underwriter.pendingRedeemRequest(reqId, depositor), DEPOSIT - DEAD_SHARES);
        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), 0);

        uint256 shares = tranche0.balanceOf(address(underwriter));
        uint256 freed = underwriter.deallocate(address(tranche0), shares);
        assertEq(freed, DEPOSIT - DEAD_SHARES);

        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), DEPOSIT - DEAD_SHARES);

        vm.prank(depositor);
        // two hops, so two seeds: one in the underwriter and one in the tranche it allocated to
        uint256 assets = underwriter.redeem(reqId, DEPOSIT - DEAD_SHARES, depositor, depositor);
        assertEq(assets, DEPOSIT - 2 * DEAD_SHARES);
        assertEq(collateral.balanceOf(depositor), DEPOSIT - 2 * DEAD_SHARES);
        assertEq(underwriter.totalSupply(), DEAD_SHARES, "the seed outlives every holder");
    }

    function test_asyncRedemption_partialWhileBorrowed_fullAfterRepay() public {
        _useTranche0AsDefault();
        _fundUnderwriter(address(underwriter), depositor, DEPOSIT);

        vm.prank(borrower);
        market.borrow(borrower, 400e18);

        vm.prank(depositor);
        uint256 reqId = underwriter.requestRedeem(DEPOSIT - DEAD_SHARES, depositor, depositor);
        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), 0);

        uint256 shares = tranche0.balanceOf(address(underwriter));
        uint256 partialFreed = underwriter.deallocate(address(tranche0), shares);
        assertGt(partialFreed, 0);
        assertLt(partialFreed, DEPOSIT);

        uint256 claimablePartial = underwriter.claimableRedeemRequest(reqId, depositor);
        assertGt(claimablePartial, 0);
        assertLt(claimablePartial, DEPOSIT);

        _mintStable(borrower, 1_000e18);
        vm.prank(borrower);
        market.repay(type(uint256).max);

        uint256 remaining = tranche0.balanceOf(address(underwriter));
        underwriter.deallocate(address(tranche0), remaining);

        assertEq(underwriter.claimableRedeemRequest(reqId, depositor), DEPOSIT - DEAD_SHARES);

        vm.prank(depositor);
        underwriter.redeem(reqId, DEPOSIT - DEAD_SHARES, depositor, depositor);
        assertEq(collateral.balanceOf(depositor), DEPOSIT - 2 * DEAD_SHARES);
    }
}
