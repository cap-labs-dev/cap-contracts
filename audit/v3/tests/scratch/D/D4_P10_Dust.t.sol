// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { WadRayMath } from "../../../../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";

/// WS-D P10: waterfall dust. Every tranche except the last one visited passes its floor
/// remainder on; the underpayment `repaid*(1+b) - slashed` is bounded by one token unit of the
/// most senior tranche that delivered anything.
contract D4_P10_Dust is CapDeployer {
    using WadRayMath for uint256;

    uint256 constant BTC_PRICE = 60_000e18;
    uint256 constant SAT_VALUE = BTC_PRICE / 1e8; // $0.0006

    FloatingMarket market;
    address senior; // WBTC 8-dec, coarse
    address junior; // WETH 18-dec, fine
    MockERC20 btc;

    function setUp() public {
        _deployCap();
        btc = _newCollateral("Wrapped Bitcoin", "WBTC", 8, BTC_PRICE);
        address[] memory assets = new address[](2);
        assets[0] = address(btc);
        assets[1] = address(collateral);
        (address m, address[] memory tranches) =
            _createMarket("D4", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        market = FloatingMarket(m);
        senior = tranches[0];
        junior = tranches[1];
        _setMarketSlopes(m);
        market.setUnderwriterRate(0);
        market.setFixedCreditLimit(10_000_000e18);
        _fundTranche(senior, address(btc), makeAddr("s"), 1e8); // 1 BTC = $60k
        _fundTranche(junior, address(collateral), makeAddr("j"), 100e18); // $100
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 30_000e18);
        _setPrice(address(btc), 35_000e18); // TC 35,100; health 0.936
        assertLt(market.healthiness(), 1e27);
    }

    function test_underpaymentBoundedByOneSeniorUnit() public {
        uint256 max = market.maxLiquidatable();
        _mintStable(defaultLiquidator, max);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(defaultLiquidator, max);
        uint256 owed = repaid.rayMul(1e27 + irm.liquidationBonus());
        uint256 unit = 35_000e18 / 1e8; // one sat at the crashed price
        emit log_named_decimal_uint("repaid (cUSD burned)     ", repaid, 18);
        emit log_named_decimal_uint("owed  = repaid*(1+b)     ", owed, 18);
        emit log_named_decimal_uint("slashed (USD delivered)  ", slashed, 18);
        emit log_named_decimal_uint("underpayment             ", owed - slashed, 18);
        emit log_named_decimal_uint("one senior unit (USD)    ", unit, 18);
        assertLt(owed, slashed + unit, "underpayment < one unit of the senior asset");
        assertGt(owed, slashed, "and there IS an underpayment");
        // junior was drained (fine-grained) and passed the exact remainder on
        assertEq(Tranche(junior).totalAssets(), 0);
    }

    /// Random repay sizes: never more than a sat short; the liquidator's bonus dwarfs it as soon
    /// as repaid > unit/b = 50 sats ($0.0175 at $35k).
    function testFuzz_underpaymentAlwaysBelowOneUnit(uint256 amount) public {
        amount = bound(amount, 1e15, market.maxLiquidatable());
        _mintStable(defaultLiquidator, amount);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(defaultLiquidator, amount);
        uint256 owed = repaid.rayMul(1e27 + irm.liquidationBonus());
        assertLt(owed, slashed + 35_000e18 / 1e8);
        // net profit at oracle price: bonus minus dust
        if (repaid > 50 * 35_000e18 / 1e8) assertGt(slashed, repaid, "profitable above 50 sats");
    }

    /// Coarsest plausible onboarded unit: a 2-decimal $1 token (GUSD-like) as the senior.
    function test_twoDecimalSenior_unitIsOneCent() public {
        _deployCap();
        MockERC20 gusd = _newCollateral("Gemini USD", "GUSD", 2, 1e18);
        address[] memory assets = new address[](2);
        assets[0] = address(gusd);
        assets[1] = address(collateral);
        (address m, address[] memory tranches) =
            _createMarket("D4b", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        FloatingMarket mk = FloatingMarket(m);
        mk.setFixedCreditLimit(10_000_000e18);
        _fundTranche(tranches[0], address(gusd), makeAddr("s2"), 100_000e2); // $100k
        _fundTranche(tranches[1], address(collateral), makeAddr("j2"), 1e18);
        vm.prank(defaultBorrower);
        mk.borrow(defaultBorrower, 50_000e18);
        _setPrice(address(gusd), 0.6e18);
        uint256 max = mk.maxLiquidatable();
        _mintStable(defaultLiquidator, max);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = mk.liquidate(defaultLiquidator, max);
        uint256 owed = repaid.rayMul(1e27 + irm.liquidationBonus());
        emit log_named_decimal_uint("underpayment (2-dec senior at $0.60)", owed - slashed, 18);
        assertLt(owed - slashed, 0.006e18 + 1, "< one unit = $0.006");
    }
}
