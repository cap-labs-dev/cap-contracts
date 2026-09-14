// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../contracts/interfaces/IBaseMarket.sol";
import { ITranche } from "../../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../../shared/CapDeployer.sol";

/// @notice Unit tests for FloatingMarket via the shared deployer.
contract MarketUnitTest is CapDeployer {
    FloatingMarket internal market;

    function setUp() public {
        _deployCap();
        address marketAddr;
        (marketAddr,,) = _createMarket("Market");
        market = FloatingMarket(marketAddr);
    }

    function test_setTrancheWeights_onlyAuthority() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.75e27;
        weights[1] = 0.25e27;
        market.setTrancheWeights(weights);
    }

    function test_setTrancheWeights_invalidTotal_reverts() public {
        uint256[] memory weights = new uint256[](2);
        weights[0] = RAY + 1;
        weights[1] = 0;
        vm.expectRevert(IBaseMarket.InvalidTrancheWeightsTotal.selector);
        market.setTrancheWeights(weights);
    }

    function test_setMaxCapital_effect() public {
        IBaseMarket.Tranche[] memory ts = market.tranches();
        ITranche(ts[0].tranche).setMaxCapital(200e18);
        ITranche(ts[1].tranche).setMaxCapital(300e18);
        assertEq(ITranche(ts[0].tranche).maxCapital(), 200e18);
        assertEq(ITranche(ts[1].tranche).maxCapital(), 300e18);
    }

    function test_marketViews() public view {
        assertEq(market.irm(), address(irm));
        assertEq(market.registry(), address(registry));
        assertEq(market.utilization(), 0);
        assertEq(market.creditLimit(), 0);
        assertEq(market.marketMultiplier(), 1e27);
    }

    function test_utilizationAndPremiumIndicesAfterADraw() public {
        IBaseMarket.Tranche[] memory tranches = market.tranches();
        _fundTranche(tranches[0].tranche, makeAddr("senior"), 10_000e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100e18);

        assertGt(market.utilization(), 0);
        assertGt(market.creditLimit(), 0);
        (uint256 liquidityIndex, uint256 underwriterIndex) = market.premiumIndices();
        assertGe(liquidityIndex, 1e27);
        assertGe(underwriterIndex, 1e27);
    }

    /// @dev An empty tranche with a {ITranche-maxCapital} used to raise the market-wide
    /// ceiling while a funded tranche with a zero cap supplied the collateral. Each tranche
    /// contributes only its own {ITranche-capitalLimit}, so that mix approves nothing.
    function test_creditLimit_emptyCappedTrancheDoesNotSponsorFundedZeroCapTranche() public {
        IBaseMarket.Tranche[] memory ts = market.tranches();
        ITranche(ts[0].tranche).setMaxCapital(1_000e18);
        ITranche(ts[1].tranche).setMaxCapital(0);
        _fundTranche(ts[1].tranche, makeAddr("junior"), 2_000e18);

        assertEq(ITranche(ts[0].tranche).capitalLimit(), 0, "empty capital contributes nothing");
        assertEq(ITranche(ts[1].tranche).capitalLimit(), 0, "a zero cap contributes nothing");
        assertEq(ITranche(ts[0].tranche).maxCapital(), 1_000e18, "the empty tranche still publishes its cap");
        assertEq(market.creditLimit(), 0, "neither side can spend the other's number");

        vm.prank(defaultBorrower);
        vm.expectRevert(IBaseMarket.InsufficientLiquidity.selector);
        market.borrow(defaultBorrower, 1);
    }

    /// @dev Unused room on one {ITranche-maxCapital} cannot lift another tranche past its own.
    function test_creditLimit_unusedCapOnOneTrancheDoesNotLiftAnother() public {
        IBaseMarket.Tranche[] memory ts = market.tranches();
        ITranche(ts[0].tranche).setMaxCapital(100e18);
        ITranche(ts[1].tranche).setMaxCapital(10_000e18);
        _fundTranche(ts[0].tranche, makeAddr("senior"), 2_000e18);
        _fundTranche(ts[1].tranche, makeAddr("junior"), 2_000e18);

        assertEq(ITranche(ts[0].tranche).capitalLimit(), 100e18, "min(2000 capital, 100 cap)");
        assertEq(ITranche(ts[1].tranche).capitalLimit(), 2_000e18, "min(2000 capital, 10000 cap)");
        // (100 + 2000) * 0.5 ltv on the market — not a market-wide mix of the two caps
        assertEq(market.creditLimit(), 1_050e18);
    }

    /// @dev {ITranche-capitalLimit} is the `min` of {ITranche-activeCapital} and {ITranche-maxCapital}.
    function test_trancheCapitalLimit_isMinOfActiveCapitalAndMaxCapital() public {
        IBaseMarket.Tranche[] memory ts = market.tranches();
        ITranche(ts[0].tranche).setMaxCapital(100e18);
        assertEq(ITranche(ts[0].tranche).capitalLimit(), 0, "no capital yet");

        _fundTranche(ts[0].tranche, makeAddr("senior"), 2_000e18);
        assertEq(ITranche(ts[0].tranche).activeCapital(), 2_000e18);
        assertEq(ITranche(ts[0].tranche).capitalLimit(), 100e18);

        ITranche(ts[0].tranche).setMaxCapital(10_000e18);
        assertEq(ITranche(ts[0].tranche).capitalLimit(), 2_000e18, "capital binds once the cap is raised");
    }
}
