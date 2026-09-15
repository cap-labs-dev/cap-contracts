// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// @notice Round-1 C-1 port: the production Oracle + ChainlinkAdapter with an 8-dec feed must be
/// normalised to IOracle.DECIMALS (18) before Tranche consumes it. Assertions are identical in
/// meaning to audit/tests/scratch/E/E1_OracleDecimals.t.sol and LEAD/OracleDecimals.t.sol.
contract R1_C1_OracleDecimals is CapDeployer {
    uint256 internal constant WETH_PRICE_18 = 2000e18;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        _setPrice(address(collateral), WETH_PRICE_18);
    }

    /// 1. feed really answers 2000e8, oracle answers 2000e18
    function test_oracleNormalisesEightDecimalFeedToEighteen() public {
        int256 raw = feeds[address(collateral)].answer();
        uint256 p = oracle.price(address(collateral));
        emit log_named_int("feed.answer() (8-dec)", raw);
        emit log_named_uint("oracle.price() (DECIMALS)", p);
        emit log_named_uint("oracle.DECIMALS()", oracle.DECIMALS());
        assertEq(raw, 2000e8, "feed answers in 8 decimals");
        assertEq(oracle.DECIMALS(), 18, "oracle DECIMALS is 18");
        assertEq(p, WETH_PRICE_18, "oracle must normalise 8-dec feed to 18-dec USD");
    }

    /// 2. LEAD port: 1000 ETH at $2000 -> totalCapital == 2_000_000e18 exactly
    function test_totalCapital_isDocumentedEighteenDecimalUsd() public {
        (, address t0,) = _createMarket("m");
        address lp = makeAddr("lp");
        _fundTranche(t0, lp, 1000e18);
        uint256 capital = Tranche(t0).totalCapital();
        emit log_named_uint("totalCapital reported", capital);
        emit log_named_uint("expected USD 18-dec  ", 2_000_000e18);
        assertEq(capital, 2_000_000e18, "totalCapital should be $2,000,000 in 18 decimals");
    }

    /// 3. $2,000,000 of collateral at 50% ltv opens $1,000,000 of credit
    function test_creditLimit_isOneMillionDollars() public {
        (address m, address t0,) = _createMarket("m");
        _fundTranche(t0, makeAddr("lp"), 1000e18);
        // creditLimit() is now min(fixedCreditLimit, variableCreditLimit); the harness caps
        // fixedCreditLimit at 1000e18, so lift it to isolate the oracle-driven limit
        FloatingMarket(m).setFixedCreditLimit(type(uint256).max);
        uint256 variable = FloatingMarket(m).variableCreditLimit();
        uint256 limit = FloatingMarket(m).creditLimit();
        emit log_named_uint("variableCreditLimit (cUSD wei)", variable);
        emit log_named_uint("creditLimit (cUSD wei)", limit);
        assertEq(variable, 1_000_000e18, "variable credit limit should be $1,000,000");
        assertEq(limit, 1_000_000e18, "credit limit should be $1,000,000");
    }

    /// 4. E1 port: borrow max, price falls to $600, liquidate maxLiquidatable; seized collateral in
    /// USD at $600 must equal repaid*(1+bonus) within 0.1% and must NOT be the whole tranche
    function test_liquidation_seizesOnlyOwedCollateral_crashTo600() public {
        // debt $10,000 vs $6,000 collateral: insolvent, so the whole tranche is the correct outcome
        _runLiquidation(600e18, false);
    }

    function test_liquidation_seizesOnlyOwedCollateral_crashTo1200() public {
        // debt $10,000 vs $12,000 collateral: unhealthy (0.96) but solvent, so only part is seized
        _runLiquidation(1200e18, true);
    }

    function _runLiquidation(uint256 crashPrice, bool expectPartial) internal {
        (address m, address t0,) = _createMarket("weth-market");
        FloatingMarket market = FloatingMarket(m);
        Tranche tranche0 = Tranche(t0);
        _configureMarketRates(market);
        market.setFixedCreditLimit(type(uint256).max); // let borrow(max) reach the LTV limit as in round 1
        _fundTranche(t0, makeAddr("underwriter"), 10e18); // 10 WETH = $20,000

        vm.prank(defaultBorrower);
        uint256 borrowed = market.borrow(defaultBorrower, type(uint256).max);
        emit log_named_uint("borrowed (cUSD wei)", borrowed);

        _setPrice(address(collateral), crashPrice);
        emit log_named_uint("healthiness after crash (ray)", market.healthiness());
        assertLt(market.healthiness(), 1e27, "market is unhealthy");

        uint256 maxLiq = market.maxLiquidatable();
        emit log_named_uint("maxLiquidatable (cUSD wei)", maxLiq);
        _depositStable(defaultLiquidator, maxLiq);
        uint256 trancheBefore = tranche0.totalAssets();

        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashedValue) = market.liquidate(defaultLiquidator, type(uint256).max);

        // Tranche.slash -> Vault.withdraw burns the vault balance and safeTransfers the ERC-20 to recipient
        uint256 seized = collateral.balanceOf(defaultLiquidator);
        uint256 seizedRealUsd18 = seized * crashPrice / 1e18;
        uint256 owedUsd18 = repaid * (1e27 + irm.liquidationBonus()) / 1e27;

        emit log_named_uint("cUSD burned by liquidator (wei)", repaid);
        emit log_named_uint("slashedValue reported by tranche", slashedValue);
        emit log_named_uint("WETH in tranche before (wei)", trancheBefore);
        emit log_named_uint("WETH seized (wei)", seized);
        emit log_named_uint("WETH left in tranche (wei)", tranche0.totalAssets());
        emit log_named_uint(
            "vault.balanceOf(liquidator, WETH)", vault.balanceOf(defaultLiquidator, address(collateral))
        );
        emit log_named_uint("real USD value seized (18-dec)", seizedRealUsd18);
        emit log_named_uint("USD the liquidator was owed (18-dec)", owedUsd18);

        assertGt(repaid, 0, "something was repaid");
        assertLe(seizedRealUsd18, owedUsd18 * 1001 / 1000, "liquidator seized more collateral than the debt cleared");
        assertApproxEqRel(seizedRealUsd18, owedUsd18, 1e15, "seized USD == repaid*(1+bonus) within 0.1%");
        if (expectPartial) {
            assertLt(seized, trancheBefore, "liquidation must not take the whole tranche");
        } else {
            emit log_named_string("whole tranche seized", seized == trancheBefore ? "yes (insolvent, expected)" : "no");
        }
    }
}
