// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IFloatingMarket } from "../../contracts/interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice Empty-market index epochs and half-up repayment inversion.
contract FloatingMarketRegressionTest is CapDeployer {
    FloatingMarket internal market;

    function setUp() public {
        _deployCap();
        (address m, address t,) = _createMarket("Floating regressions");
        market = FloatingMarket(m);
        _fundTranche(t, makeAddr("supplier"), 1_000e18);
        _indices(RAY, RAY);
    }

    function _indices(uint256 liquidity, uint256 underwriting) internal {
        vm.mockCall(address(irm), abi.encodeCall(IInterestRateModel.liquidityIndex, ()), abi.encode(liquidity));
        vm.mockCall(
            address(irm),
            abi.encodeCall(IInterestRateModel.underwriterIndex, (address(market))),
            abi.encode(underwriting)
        );
    }

    function test_initializationEmitsTheMarketLocalIndexBaseline() public {
        _indices(1.5e27, RAY);
        vm.expectEmit();
        emit IFloatingMarket.PremiumIndexUpdated(RAY, RAY);
        vm.prank(address(registry));
        address created = beaconFactory.create(
            floatingMarketBeacon,
            abi.encodeCall(IFloatingMarket.initialize, (address(accessManager), address(registry), "Index baseline"))
        );
        (uint256 liquidity, uint256 underwriting) = FloatingMarket(created).premiumIndices();
        assertEq(liquidity, RAY, "a new market starts a local epoch regardless of the global index");
        assertEq(underwriting, RAY);
    }

    function test_dormantEmptyMarketSkipsUnrepresentableLocalGrowthAndCanBorrowAgain() public {
        vm.mockCall(address(irm), abi.encodeCall(IInterestRateModel.maximumMarketMultiplier, ()), abi.encode(4e27));
        market.setMarketMultiplier(4e27);
        vm.warp(block.timestamp + 100 days);
        _indices(1e45, 2e27);
        // Growing the old local index would raise 1e18 to the fourth power in ray units.
        assertEq(market.totalDebt(), 0);
        (uint256 liquidity, uint256 underwriting) = market.premiumIndices();
        assertEq(liquidity, RAY);
        assertEq(underwriting, 2e27);
        assertEq(market.index(), 2e27);
        uint256 credit = stablecoin.creditBackedSupply();
        vm.expectEmit(address(market));
        emit IFloatingMarket.PremiumIndexUpdated(RAY, 2e27);
        vm.prank(makeAddr("permissionless caller"));
        market.chargePremium();
        assertEq(stablecoin.creditBackedSupply(), credit);
        (liquidity, underwriting) = market.premium();
        assertEq(liquidity + underwriting, 0);

        vm.prank(defaultBorrower);
        assertEq(market.borrow(defaultBorrower, 100e18), 100e18);
        assertEq(market.totalDebt(), 100e18);
        assertEq(stablecoin.creditBackedSupply() - credit, 100e18);
        vm.warp(block.timestamp + 1);
        _indices(1.01e45, 2e27);
        uint256 growth = market.totalDebt() - 100e18;
        assertGt(growth, 0);
        market.chargePremium();
        assertEq(stablecoin.creditBackedSupply() - credit, market.totalDebt());
    }

    function test_fullRepaymentThenSameBlockBorrowStartsANewEpoch() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100e18);
        vm.warp(block.timestamp + 1);
        _indices(1.2e27, 1.1e27);
        vm.expectEmit(address(market));
        emit IFloatingMarket.PremiumIndexUpdated(1.2e27, 1.1e27);
        market.chargePremium();
        assertEq(market.totalDebt(), 132e18);
        _mintStable(defaultBorrower, 32e18);
        vm.startPrank(defaultBorrower);
        assertEq(market.repay(type(uint256).max), 132e18);
        assertEq(market.totalDebt(), 0);
        (uint256 l, uint256 u) = market.premiumIndices();
        assertEq(l, RAY);
        assertEq(u, 1.1e27);
        assertEq(market.index(), u);
        vm.expectEmit(address(market));
        emit IFloatingMarket.PremiumIndexUpdated(RAY, 1.1e27);
        uint256 minted = market.borrow(defaultBorrower, 55e18);
        vm.stopPrank();
        assertEq(minted, 55e18);
        assertEq(market.totalDebt(), minted);
        (l, u) = market.premiumIndices();
        assertEq(l, RAY, "same-block reborrow must replace the previous local baseline");
        assertEq(u, 1.1e27);
        vm.warp(block.timestamp + 1);
        assertEq(market.totalDebt(), minted, "no historical premium charged to the new borrowing");
    }

    function test_fundedSameBlockCheckpointKeepsItsCachedIndices() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100e18);
        _indices(1.2e27, 1.1e27);
        assertEq(market.index(), RAY);
        vm.recordLogs();
        market.chargePremium();
        assertEq(vm.getRecordedLogs().length, 0, "cached indices do not emit another checkpoint");
        assertEq(market.totalDebt(), 100e18);
        vm.warp(block.timestamp + 1);
        assertEq(market.totalDebt(), 132e18);
        market.chargePremium();
        uint256 credit = stablecoin.creditBackedSupply();
        vm.recordLogs();
        market.chargePremium();
        assertEq(vm.getRecordedLogs().length, 0, "a repeated charge does not advance the clock");
        assertEq(stablecoin.creditBackedSupply(), credit, "no duplicate premium");
    }

    function test_halfUpRepayAcceptsTheOneWeiFillDiscardedByCeil() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 14);
        vm.warp(block.timestamp + 1);
        _indices(RAY, 1.5e27);
        market.chargePremium();
        assertEq(market.totalDebt(), 21);
        uint256 credit = stablecoin.creditBackedSupply();
        vm.prank(defaultBorrower);
        assertEq(market.repay(1), 1);
        assertEq(market.totalDebt(), 20, "13 scaled units round half up to 20");
        assertEq(stablecoin.creditBackedSupply(), credit - 1);
    }

    function test_largeIndexProductStillRealizesExactlyTheDebtGrowth() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100e18);
        vm.warp(block.timestamp + 1);
        _indices(1e35, 1e45);
        assertEq(market.index(), 1e53, "the unscaled index product exceeds 256 bits");
        assertEq(market.totalDebt(), 1e46);
        market.chargePremium();
        assertEq(stablecoin.creditBackedSupply(), 1e46);
        _mintStable(defaultBorrower, 1e46 - 100e18);
        vm.prank(defaultBorrower);
        assertEq(market.repay(type(uint256).max), 1e46);
        assertEq(market.totalDebt(), 0);
    }

    /// @dev Exhaustively enumerate small scaled balances, independently of the production inverse.
    function testFuzz_repayIsTheLargestRepresentableFill(uint8 rawScaled, uint64 rawIndex, uint16 rawRequest) public {
        uint256 scaled = bound(rawScaled, 2, 100);
        uint256 idx = RAY + uint256(rawIndex) * 1e9;
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, scaled);
        vm.warp(block.timestamp + 1);
        _indices(RAY, idx);
        market.chargePremium();
        uint256 debt = market.totalDebt();
        uint256 requested = bound(rawRequest, 1, debt - 1);
        uint256 best;
        for (uint256 remaining; remaining < scaled; ++remaining) {
            uint256 reduction = debt - (remaining * idx + RAY / 2) / RAY;
            if (reduction <= requested && reduction > best) best = reduction;
        }
        _mintStable(defaultBorrower, debt);
        uint256 credit = stablecoin.creditBackedSupply();
        uint256 balance = stablecoin.balanceOf(defaultBorrower);
        vm.prank(defaultBorrower);
        if (best == 0) {
            vm.expectRevert(IFloatingMarket.InvalidScaledAmount.selector);
            market.repay(requested);
        } else {
            assertEq(market.repay(requested), best);
        }
        assertEq(market.totalDebt(), debt - best);
        assertEq(stablecoin.creditBackedSupply(), credit - best);
        assertEq(stablecoin.balanceOf(defaultBorrower), balance - best);
    }
}
