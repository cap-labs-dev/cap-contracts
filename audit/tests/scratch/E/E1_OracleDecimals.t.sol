// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { RealOracleDeployer } from "./RealOracleDeployer.sol";

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";

/// @notice E-1: the production Oracle answers in 8 decimals, Tranche consumes the answer as if it
/// were 18 decimals. Every USD figure the markets compute off collateral is 1e10x too small.
contract E1_OracleDecimals is RealOracleDeployer {
    uint256 internal constant WETH_PRICE_8 = 2000e8; // $2000, Chainlink scale
    uint256 internal constant WETH_PRICE_18 = 2000e18; // what ITranche documents as the scale
    uint256 internal constant DEPOSIT = 10e18; // 10 WETH = $20,000 real

    address internal underwriter = makeAddr("underwriter");
    address internal marketAddr;
    Tranche internal tranche0;
    FloatingMarket internal market;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCapWithRealOracle(int256(WETH_PRICE_8));

        (address m, address t0,) = _createMarket("weth-market");
        marketAddr = m;
        market = FloatingMarket(m);
        tranche0 = Tranche(t0);
        _configureMarketRates(market);
        _fundTranche(t0, underwriter, DEPOSIT);
    }

    /// @dev The oracle really does answer 8 decimals through the adapter
    function test_oracleAnswersEightDecimals() public view {
        (uint256 p,) = realOracle.price(address(collateral));
        assertEq(p, WETH_PRICE_8);
    }

    /// @dev ITranche.totalCapital: "The total capital value of the tranche in USD (18 decimals)"
    function test_totalCapital_isDocumentedEighteenDecimalUsd() public {
        uint256 intended = DEPOSIT * WETH_PRICE_18 / 1e18; // 20_000e18
        uint256 actual = tranche0.totalCapital();
        emit log_named_uint("intended totalCapital (18-dec USD)", intended);
        emit log_named_uint("actual   totalCapital", actual);
        emit log_named_uint("ratio intended/actual", intended / actual);
        assertEq(actual, intended, "totalCapital is 1e10x below the documented scale");
    }

    /// @dev $20,000 of collateral at 50% ltv should open $10,000 of credit. It opens 1e-6 cUSD.
    function test_creditLimit_isTenThousandDollars() public {
        uint256 limit = market.creditLimit();
        emit log_named_uint("creditLimit (cUSD wei)", limit);
        assertEq(limit, 10_000e18, "credit limit is 1e10x below intended");
    }

    /// @dev lockedValue = debt / (lt - buffer) = 1.43e12 cUSD-wei. At the documented 18-dec price
    /// that locks 7.1e8 wei of WETH; at the 8-dec price it locks 7.1e18 wei = 71% of the tranche
    function test_dustDebtLocksMostOfTheTranche() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);
        uint256 intendedLockedAssets = market.lockedValue(address(tranche0)) * 1e18 / WETH_PRICE_18;
        uint256 unlocked = tranche0.unlockedSupply();
        emit log_named_uint("intended locked WETH (wei)", intendedLockedAssets);
        emit log_named_uint("actual unlocked shares", unlocked);
        assertGe(unlocked, DEPOSIT - intendedLockedAssets - 1e12, "1e-6 cUSD of debt locks 71% of a $20k tranche");
    }

    /// @dev Borrow the dust that IS allowed, let the price fall 70%, liquidate: the tranche is
    /// slashed at the 8-dec price so `assets = value * 1e18 / price` is 1e10x too many, capped at
    /// the whole tranche. The liquidator burns ~6e-7 cUSD and walks away with all 10 WETH.
    function test_liquidation_takesWholeTrancheForDust() public {
        vm.prank(defaultBorrower);
        uint256 borrowed = market.borrow(defaultBorrower, type(uint256).max);
        emit log_named_uint("borrowed (cUSD wei)", borrowed); // ~1e12 = 0.000001 cUSD

        // collateral falls 70%: $2000 -> $600. Real collateral value is now $6,000.
        feed.setAnswer(600e8);
        assertLt(market.healthiness(), 1e27, "market is unhealthy");

        uint256 maxLiq = market.maxLiquidatable();
        _depositStable(defaultLiquidator, maxLiq);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashedValue) = market.liquidate(defaultLiquidator, type(uint256).max);

        uint256 seized = collateral.balanceOf(defaultLiquidator); // Tranche.slash -> Vault.withdraw pays the ERC-20 out directly
        uint256 seizedRealUsd18 = seized * 600e18 / 1e18;
        uint256 owedUsd18 = repaid * (1e27 + irm.liquidationBonus()) / 1e27;

        emit log_named_uint("cUSD burned by liquidator (wei)", repaid);
        emit log_named_uint("slashedValue reported by tranche", slashedValue);
        emit log_named_uint("WETH seized (wei)", seized);
        emit log_named_uint("WETH left in tranche (wei)", tranche0.totalAssets());
        emit log_named_uint("real USD value seized (18-dec)", seizedRealUsd18);
        emit log_named_uint("USD the liquidator was owed (18-dec)", owedUsd18);

        // the liquidator may take at most (1 + bonus) per unit of debt cleared
        assertLe(
            seizedRealUsd18, owedUsd18 * 1001 / 1000, "liquidator seized 1e10x more collateral than the debt cleared"
        );
    }
}
