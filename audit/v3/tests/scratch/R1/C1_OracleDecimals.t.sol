// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 re-check of round-1 C-1 (FIXED in round 2): Oracle.DECIMALS == 18
/// (Oracle.sol:16), ChainlinkAdapter normalises 8-dec feeds (ChainlinkAdapter.sol:29-31),
/// Tranche consumes 18-dec USD (Tranche.sol:177-181, :71-95).
contract R1_C1_OracleDecimals is CapDeployer {
    uint256 internal constant WETH_PRICE_18 = 2000e18;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        _setPrice(address(collateral), WETH_PRICE_18);
    }

    function test_oracleNormalisesEightDecimalFeedToEighteen() public view {
        int256 raw = feeds[address(collateral)].answer();
        assertEq(raw, 2000e8, "feed answers in 8 decimals");
        assertEq(oracle.DECIMALS(), 18, "oracle DECIMALS is 18");
        assertEq(oracle.price(address(collateral)), WETH_PRICE_18, "oracle must normalise 8-dec feed to 18-dec USD");
    }

    function test_totalCapital_isDocumentedEighteenDecimalUsd() public {
        (, address t0,) = _createMarket("m");
        _fundTranche(t0, makeAddr("lp"), 1000e18);
        assertEq(Tranche(t0).totalCapital(), 2_000_000e18, "totalCapital should be $2,000,000 in 18 decimals");
    }

    function test_creditLimit_isOneMillionDollars() public {
        (address m, address t0,) = _createMarket("m");
        _fundTranche(t0, makeAddr("lp"), 1000e18);
        FloatingMarket(m).setFixedCreditLimit(type(uint256).max);
        assertEq(FloatingMarket(m).variableCreditLimit(), 1_000_000e18, "variable credit limit should be $1,000,000");
        assertEq(FloatingMarket(m).creditLimit(), 1_000_000e18, "credit limit should be $1,000,000");
    }

    function test_liquidation_seizesOnlyOwedCollateral_crashTo1200() public {
        (address m, address t0,) = _createMarket("weth-market");
        FloatingMarket market = FloatingMarket(m);
        Tranche tranche0 = Tranche(t0);
        _configureMarketRates(market);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(t0, makeAddr("underwriter"), 10e18); // 10 WETH = $20,000

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);
        _setPrice(address(collateral), 1200e18);
        assertLt(market.healthiness(), 1e27, "market is unhealthy");

        uint256 maxLiq = market.maxLiquidatable();
        _depositStable(defaultLiquidator, maxLiq);
        uint256 trancheBefore = tranche0.totalAssets();
        vm.prank(defaultLiquidator);
        (uint256 repaid,) = market.liquidate(defaultLiquidator, type(uint256).max);

        uint256 seized = collateral.balanceOf(defaultLiquidator);
        uint256 seizedRealUsd18 = seized * 1200e18 / 1e18;
        uint256 owedUsd18 = repaid * (1e27 + irm.liquidationBonus()) / 1e27;
        emit log_named_uint("cUSD burned by liquidator (wei)", repaid);
        emit log_named_uint("WETH seized (wei)", seized);
        emit log_named_uint("real USD value seized (18-dec)", seizedRealUsd18);
        emit log_named_uint("USD the liquidator was owed (18-dec)", owedUsd18);
        assertGt(repaid, 0);
        assertLe(seizedRealUsd18, owedUsd18 * 1001 / 1000, "liquidator seized more collateral than the debt cleared");
        assertApproxEqRel(seizedRealUsd18, owedUsd18, 1e15, "seized USD == repaid*(1+bonus) within 0.1%");
        assertLt(seized, trancheBefore, "liquidation must not take the whole tranche");
    }
}
