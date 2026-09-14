// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../contracts/interfaces/IBaseMarket.sol";
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

    function test_setFixedCreditLimit_effect() public {
        market.setFixedCreditLimit(500e18);
        assertEq(market.fixedCreditLimit(), 500e18);
    }

    function test_marketViews() public view {
        assertEq(market.irm(), address(irm));
        assertEq(market.registry(), address(registry));
        assertEq(market.utilization(), 0);
        assertEq(market.variableCreditLimit(), 0);
        assertEq(market.marketMultiplier(), 1e27);
    }

    function test_utilizationAndPremiumIndicesAfterADraw() public {
        IBaseMarket.Tranche[] memory tranches = market.tranches();
        _fundTranche(tranches[0].tranche, makeAddr("senior"), 10_000e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 100e18);

        assertGt(market.utilization(), 0);
        assertGt(market.variableCreditLimit(), 0);
        (uint256 liquidityIndex, uint256 underwriterIndex) = market.premiumIndices();
        assertGe(liquidityIndex, 1e27);
        assertGe(underwriterIndex, 1e27);
    }
}
