// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { MarketLimits } from "../../contracts/utils/MarketLimits.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice Bounded market configuration, post-loss credit, and one collateral valuation per preflight.
contract MarketLimitsRegressionTest is CapDeployer {
    FloatingMarket internal market;
    Tranche internal senior;
    Tranche internal junior;

    function setUp() public {
        _deployCap();
        (address m, address s, address j) = _createMarket("Market limits");
        market = FloatingMarket(m);
        senior = Tranche(s);
        junior = Tranche(j);
    }

    function test_bufferEndpointsAndImmediateCreditTightening() public {
        _fundTranche(address(senior), makeAddr("supplier"), 1_000e18);
        market.setBuffer(0.1e27);
        assertEq(market.creditLimit(), 500e18);
        vm.expectRevert(IBaseMarket.InvalidBuffer.selector);
        market.setBuffer(0.1e27 - 1);
        vm.expectRevert(IBaseMarket.InvalidBuffer.selector);
        market.setBuffer(0.8e27);
        market.setBuffer(0.4e27);
        assertEq(market.creditLimit(), 400e18);
        assertEq(market.ltv(), 0.5e27, "risk tightening need not change the owner's stored LTV");
        market.setLt(0.6e27);
        assertEq(market.creditLimit(), 200e18);
        vm.expectRevert(IBaseMarket.InvalidLt.selector);
        market.setLt(0.4e27);
    }

    function test_marketInitializationAlsoRejectsSubMinimumBuffer() public {
        vm.mockCall(address(registry), abi.encodeWithSignature("buffer()"), abi.encode(0.1e27 - 1));
        FloatingMarket implementation = new FloatingMarket();
        vm.expectRevert(IBaseMarket.InvalidBuffer.selector);
        _deployProxy(
            address(implementation),
            abi.encodeCall(FloatingMarket.initialize, (address(accessManager), address(registry), "invalid"))
        );
    }

    function _weights(uint256 count) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](count);
        weights[0] = RAY;
    }

    function test_floatingCreationAcceptsTenTranchesAndRejectsEleven() public {
        (address m, address[] memory ts) =
            _createMarket("Ten floating", defaultMarketOwner, defaultBorrower, _weights(10));
        assertEq(ts.length, 10);
        assertEq(IBaseMarket(m).tranches().length, 10);
        uint64 role = _operatorRoleOf(defaultMarketOwner);
        address[] memory assets = _uniformAssets(11);
        uint256[] memory weights = _weights(11);
        vm.expectRevert(IBaseMarket.TooManyTranches.selector);
        registry.createFloatingMarket(assets, weights, "Eleven", role);
    }

    function test_fixedCreationAcceptsTenTranchesAndRejectsEleven() public {
        (address m, address[] memory ts) =
            _createFixedMarket("Ten fixed", defaultMarketOwner, defaultBorrower, _weights(10));
        assertEq(ts.length, 10);
        assertEq(IBaseMarket(m).tranches().length, 10);
        uint64 role = _operatorRoleOf(defaultMarketOwner);
        address[] memory assets = _uniformAssets(11);
        uint256[] memory weights = _weights(11);
        vm.expectRevert(IBaseMarket.TooManyTranches.selector);
        registry.createFixedMarket(assets, weights, "Eleven", role, 30 days, 1 days, 1 days);
    }

    function test_appendingCountsEmptyKilledAndZeroWeightTranches() public {
        _fundTranche(address(junior), makeAddr("supplier"), 1e18);
        vm.prank(address(market));
        junior.slash(1e18, makeAddr("recipient"));
        assertTrue(junior.killed());
        for (uint256 count = 3; count <= 10; ++count) {
            vm.prank(defaultMarketOwner);
            registry.createTranche(address(market), address(collateral), _weights(count), 12 hours);
        }
        assertEq(market.tranches().length, 10);
        uint256[] memory weights = _weights(11);
        vm.prank(defaultMarketOwner);
        vm.expectRevert(IBaseMarket.TooManyTranches.selector);
        registry.createTranche(address(market), address(collateral), weights, 12 hours);
        assertEq(market.tranches().length, 10);
    }

    function test_directTrancheUpdateRejectsElevenBeforePremiumCheckpoint() public {
        IBaseMarket.Tranche[] memory tooMany = new IBaseMarket.Tranche[](11);
        // An empty-market checkpoint would hit this; the length check must be earlier.
        vm.mockCallRevert(address(irm), abi.encodeCall(IInterestRateModel.liquidityIndex, ()), "checkpoint reached");
        vm.prank(address(registry));
        vm.expectRevert(IBaseMarket.TooManyTranches.selector);
        market.setTranches(tooMany);
        assertEq(market.tranches().length, 2);
    }

    function testFuzz_allowedRiskBoundsLeaveNoCreditAfterWriteOff(uint96 rawLt, uint96 rawBuffer, uint96 rawBonus)
        public
    {
        _fundTranche(address(senior), makeAddr("supplier"), 1_000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
        uint256 lt = bound(rawLt, MarketLimits.MIN_BUFFER + 1, MarketLimits.MAX_LT);
        uint256 buffer = bound(rawBuffer, MarketLimits.MIN_BUFFER, lt - 1);
        uint256 bonus = bound(rawBonus, 0, MarketLimits.MAX_LIQUIDATION_BONUS);
        market.setLt(lt);
        market.setBuffer(buffer);
        irm.setLiquidationBonus(bonus);
        assertLt((lt - buffer) * (RAY + bonus), RAY * RAY, "credit ratio stays below recoverable collateral");
        assertGt(MarketLimits.MIN_TARGET_HEALTH * RAY, lt * (RAY + bonus));
        _setPrice(address(collateral), 0.1e18);
        assertGt(market.writeOff(), 0);
        assertEq(market.availableCredit(), 0);
        assertGe(market.totalDebt(), market.creditLimit());
    }

    function test_healthyWriteOffResidualIsAllowedButCannotBorrow() public {
        _fundTranche(address(senior), makeAddr("supplier"), 1_000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
        market.setLt(RAY);
        irm.setLiquidationBonus(0.1e27);
        _setPrice(address(collateral), 0.1e18);
        assertGt(market.writeOff(), 0);
        assertGe(market.healthiness(), RAY, "healthy residual is the documented write-off policy");
        assertEq(market.maxLiquidatable(), 0);
        assertEq(market.availableCredit(), 0);
    }

    function test_fixedWriteOffAlsoLeavesNoBorrowingCapacity() public {
        (address m, address t,) = _createFixedMarket("Fixed write-off");
        FixedMarket fixedMarket = FixedMarket(m);
        _fundTranche(t, makeAddr("supplier"), 1_000e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = fixedMarket.borrow(defaultBorrower, 400e18, 30 days);
        fixedMarket.setLt(RAY);
        irm.setLiquidationBonus(0.1e27);
        _setPrice(address(collateral), 0.1e18);
        assertGt(fixedMarket.writeOff(id), 0);
        assertEq(fixedMarket.availableCredit(), 0);
        assertEq(fixedMarket.availableCredit(30 days), 0);
    }

    function test_floatingLiquidationValuesEachTrancheOnce() public {
        _fundTranche(address(senior), makeAddr("supplier"), 1_000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
        _setPrice(address(collateral), 0.4e18);
        _mintStable(defaultLiquidator, 100e18);
        vm.expectCall(address(senior), abi.encodeCall(ITranche.totalCapital, ()), uint64(1));
        vm.expectCall(address(junior), abi.encodeCall(ITranche.totalCapital, ()), uint64(1));
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(defaultLiquidator, 100e18);
        assertEq(repaid, 100e18);
        assertEq(slashed, 102e18);
    }

    function test_fixedLiquidationValuesEachTrancheOnce() public {
        (address m, address s, address j) = _createFixedMarket("Fixed valuation");
        FixedMarket fixedMarket = FixedMarket(m);
        _fundTranche(s, makeAddr("supplier"), 1_000e18);
        vm.prank(defaultBorrower);
        (uint256 id,) = fixedMarket.borrow(defaultBorrower, 400e18, 30 days);
        _setPrice(address(collateral), 0.4e18);
        _mintStable(defaultLiquidator, 100e18);
        vm.expectCall(s, abi.encodeCall(ITranche.totalCapital, ()), uint64(1));
        vm.expectCall(j, abi.encodeCall(ITranche.totalCapital, ()), uint64(1));
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = fixedMarket.liquidate(id, defaultLiquidator, 100e18);
        assertEq(repaid, 100e18);
        assertEq(slashed, 102e18);
    }
}
