// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @title PricedCollateralTest
/// @notice Liquidation is denominated in debt value while tranches hold token amounts, so every
/// slash has to round-trip through the oracle price. These cases use collateral priced away from
/// 1.0 so a missing conversion cannot pass unnoticed.
contract PricedCollateralTest is CapDeployer {
    uint256 internal constant LIQUIDATION_BONUS = 0.02e27;

    function _setUpMarketAtPrice(uint256 price, uint256 seniorAssets, uint256 juniorAssets)
        internal
        returns (FloatingMarket market, address senior, address junior)
    {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.collateralPrice = price;
        _deployCapWithConfig(cfg);

        address marketAddr;
        (marketAddr, senior, junior) = _createMarket("Priced");
        market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        market.setFixedCreditLimit(100_000e18);

        _fundTranche(senior, makeAddr("senior"), seniorAssets);
        _fundTranche(junior, makeAddr("junior"), juniorAssets);
    }

    /// Collateral worth $2 means $102 of slashing should remove 51 tokens, not 102.
    function test_slash_convertsValueToAssets_priceAboveOne() public {
        (FloatingMarket market,, address junior) = _setUpMarketAtPrice(2e18, 500e18, 500e18);

        assertEq(market.totalCapital(), 2_000e18, "1000 tokens at $2");

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 900e18);

        market.setLt(0.4e27);
        assertGt(market.maxLiquidatable(), 100e18, "market should be liquidatable");

        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(defaultLiquidator, 100e18);

        assertEq(repaid, 100e18, "repaid the requested amount");
        assertEq(slashed, 102e18, "slashed value includes the 2% bonus");
        assertEq(collateral.balanceOf(defaultLiquidator), 51e18, "$102 of collateral at $2 = 51 tokens");
        assertEq(Tranche(junior).totalAssets(), 449e18, "junior absorbed the slash");
    }

    /// Collateral worth $0.50 means $102 of slashing should remove 204 tokens.
    function test_slash_convertsValueToAssets_priceBelowOne() public {
        (FloatingMarket market,,) = _setUpMarketAtPrice(0.5e18, 500e18, 500e18);

        assertEq(market.totalCapital(), 500e18, "1000 tokens at $0.50");

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 240e18);

        market.setLt(0.2e27);
        assertGt(market.maxLiquidatable(), 100e18, "market should be liquidatable");

        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        (, uint256 slashed) = market.liquidate(defaultLiquidator, 100e18);

        assertEq(slashed, 102e18, "slashed value includes the 2% bonus");
        assertEq(collateral.balanceOf(defaultLiquidator), 204e18, "$102 of collateral at $0.50 = 204 tokens");
    }

    /// The cascade must keep converting correctly once the junior tranche is exhausted.
    function test_slash_cascadesAcrossTranchesAtPrice() public {
        (FloatingMarket market, address senior, address junior) = _setUpMarketAtPrice(2e18, 500e18, 20e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        market.setLt(0.4e27);
        assertGt(market.maxLiquidatable(), 100e18, "market should be liquidatable");

        _mintStable(defaultLiquidator, 100e18);
        vm.prank(defaultLiquidator);
        (, uint256 slashed) = market.liquidate(defaultLiquidator, 100e18);

        assertEq(slashed, 102e18, "full value slashed across both tranches");
        assertEq(Tranche(junior).totalAssets(), 0, "junior drained first");
        assertEq(Tranche(senior).totalAssets(), 469e18, "senior covered the remainder");
        // 20 tokens ($40) from the junior + 31 tokens ($62) from the senior
        assertEq(collateral.balanceOf(defaultLiquidator), 51e18, "51 tokens total at $2");
    }

    /// The whole point of {IBaseMarket-maxLiquidatable} is to be the repayment that restores
    /// {IBaseMarket-targetHealth}, so liquidating exactly that figure has to land on it. Each unit
    /// of debt cleared costs `1 + bonus` of collateral rather than one, and pricing the collateral
    /// leg at par instead left the divisor too large: the same crash below used to be quoted at
    /// 722 and settle at a health of 1.185 against a target of 1.25.
    function test_liquidatingTheMaximumLandsOnTargetHealth() public {
        (FloatingMarket market,,) = _setUpMarketAtPrice(2e18, 500e18, 500e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 900e18);

        // halve the collateral: $1000 against $900 of debt is unhealthy but still fully recoverable,
        // so the cap is not what is being measured here
        oracle.setPrice(address(collateral), 1e18);
        assertEq(market.totalCapital(), 1_000e18, "capital repriced");
        assertLt(market.healthiness(), 1e27, "and the market is unhealthy");
        assertGt(market.recoverableDebt(), 900e18, "with every dollar of it still recoverable");

        uint256 max = market.maxLiquidatable();
        assertLt(max, 900e18, "so the debt itself is not the binding cap");

        _mintStable(defaultLiquidator, max);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, max);

        assertApproxEqRel(market.healthiness(), market.targetHealth(), 0.0001e18, "lands on target, not short of it");
    }

    /// After a collateral crash the debt far exceeds the whole market, and the binding cap is
    /// {IBaseMarket-recoverableDebt} rather than the debt itself. The tranches can only hand over
    /// what they hold, so past that point every further unit of cUSD burned buys collateral that
    /// is not there: the liquidator eats the difference and health falls instead of rising. Left
    /// uncapped this call took $900 for $100 of collateral. What remains is a shortfall for
    /// {IBaseMarket-writeOff}, not something a liquidation can reach.
    function test_liquidationAfterAPriceCrashStopsAtTheRecoverablePoint() public {
        (FloatingMarket market, address senior, address junior) = _setUpMarketAtPrice(2e18, 500e18, 500e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 900e18);

        // collateral falls from $2 to $0.10, leaving 1000 tokens worth only $100
        oracle.setPrice(address(collateral), 0.1e18);
        assertEq(market.totalCapital(), 100e18, "capital repriced");

        uint256 recoverable = market.recoverableDebt();
        assertEq(market.maxLiquidatable(), recoverable, "capped at what the collateral can clear");
        assertLt(recoverable, 900e18, "which is well short of the debt");

        // ask for the whole debt anyway, so the cap is what does the trimming
        _mintStable(defaultLiquidator, 900e18);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(defaultLiquidator, 900e18);

        assertEq(repaid, recoverable, "an oversized request is trimmed to the cap");
        assertEq(slashed, 100e18, "which is exactly the $100 the tranches still held");
        assertEq(collateral.balanceOf(defaultLiquidator), 1_000e18, "all collateral seized");
        assertEq(Tranche(senior).totalAssets(), 0, "senior drained");
        assertEq(Tranche(junior).totalAssets(), 0, "junior drained");

        // the liquidator collects their bonus rather than paying a penalty, and the rest of the
        // debt is left standing as the shortfall the guardian writes off
        assertApproxEqRel(slashed, repaid * 102 / 100, 0.0001e18, "paid at the bonus, not below it");
        assertEq(market.totalDebt(), 900e18 - recoverable, "the shortfall survives the liquidation");
        assertEq(market.unrecoverableDebt(), 900e18 - recoverable, "and is exactly what writeOff is for");
    }
}
