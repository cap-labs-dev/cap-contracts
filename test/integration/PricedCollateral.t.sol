// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { WadRayMath } from "../../contracts/utils/WadRayMath.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";

/// @title PricedCollateralTest
/// @notice Liquidation is denominated in debt value while tranches hold token amounts, so every
/// slash has to round-trip through the oracle price. These cases use collateral priced away from
/// 1.0 so a missing conversion cannot pass unnoticed.
contract PricedCollateralTest is CapDeployer {
    using WadRayMath for uint256;

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

    /// @dev The scale itself, which none of the cases below can pin because they all quote a price
    /// and an expectation in the same units and so hold only for the ratio between them.
    ///
    /// A price is never used on its own here. Every consumer multiplies a token amount by one to
    /// get a USD value and then compares that value against cUSD debt, so the oracle's scale has
    /// to be cUSD's or the comparison is off by the difference. It was: the oracle answered in a
    /// feed's native eight while {ITranche-totalCapital} and {IBaseMarket-lockedValue} carried
    /// that straight into eighteen-decimal terms, undervaluing all collateral by ten orders of
    /// magnitude and leaving every market both unable to lend and instantly liquidatable. Nothing
    /// caught it because the harness mocked the oracle and answered in eighteen regardless of what
    /// the real one did, so this suite runs on the real {Oracle} and the real {ChainlinkAdapter}
    /// over an eight-decimal feed, and the normalisation between them is live.
    ///
    /// Both halves are needed. The equality states the invariant and would survive someone moving
    /// both constants together; the amounts are absolute, so they would not.
    function test_aPriceIsDenominatedInTheSameScaleAsTheDebtItIsComparedAgainst() public {
        (FloatingMarket market,,) = _setUpMarketAtPrice(1e18, 1e18, 1e18);

        assertEq(oracle.DECIMALS(), stablecoin.decimals(), "a price is a cUSD value, so it carries cUSD's scale");
        assertEq(market.totalCapital(), 2e18, "two whole tokens at a dollar each back two whole cUSD");

        // and the route is genuinely crossed. Feeds reporting in the oracle's own scale would make
        // the adapter's normalisation a no-op, which is the shape the suite had when it mocked the
        // oracle: still green, and blind to exactly the disagreement above
        assertTrue(FEED_DECIMALS != oracle.DECIMALS(), "the feeds behind these prices need normalising");

        // and the value is load-bearing, not just reported: at the default half LTV it has to buy
        // a whole cUSD of credit rather than a ten-billionth of one
        assertEq(market.creditLimit(), 1e18, "half of two dollars is a dollar of borrowing power");

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 1e18);

        assertEq(stablecoin.balanceOf(defaultBorrower), 1e18, "and it is actually borrowable");
        assertGe(market.healthiness(), 1e27, "leaving the market healthy at exactly its limit");
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
        _setPrice(address(collateral), 1e18);
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
        _setPrice(address(collateral), 0.1e18);
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

    /// @dev Eight-decimal collateral at $100,000: one token unit is $0.001. A $0.0009 request
    /// floors to zero tokens. The non-capped branch used to return the request anyway, so the
    /// waterfall subtracted value that never left the vault.
    function test_slash_reportsZeroWhenTheRequestIsBelowOneToken() public {
        (,, address junior, MockERC20 btc) = _btcJuniorMarket();
        address recipient = makeAddr("recipient");

        vm.prank(Tranche(junior).market());
        uint256 slashed = Tranche(junior).slash(0.0009e18, recipient);

        assertEq(slashed, 0, "no USD was delivered");
        assertEq(Tranche(junior).totalAssets(), 1e8, "no tokens left the vault");
        assertEq(btc.balanceOf(recipient), 0);
    }

    /// @dev One and a half sats of value can only move one sat. Report that sat, not the request.
    function test_slash_reportsTheTokensThatMoved() public {
        (,, address junior, MockERC20 btc) = _btcJuniorMarket();
        address recipient = makeAddr("recipient");
        uint256 satValue = 100_000e18 / 1e8;

        vm.prank(Tranche(junior).market());
        uint256 slashed = Tranche(junior).slash(satValue + satValue / 2, recipient);

        assertEq(slashed, satValue, "floored to the sat that moved");
        assertEq(btc.balanceOf(recipient), 1);
        assertEq(Tranche(junior).totalAssets(), 1e8 - 1);
    }

    /// @dev A repayment whose bonus is worth less than one junior sat used to close the waterfall
    /// after a zero-token slash. The remainder now lands on the senior.
    function test_liquidation_carriesDustBelowOneTokenToTheNextTranche() public {
        (FloatingMarket market, address senior, address junior, MockERC20 btc) = _btcJuniorMarket();

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 40_000e18);
        market.setLt(0.3e27);
        assertLt(market.healthiness(), 1e27, "unhealthy");

        uint256 repay = 0.0009e18;
        uint256 toSlash = repay.rayMul(1e27 + irm.liquidationBonus());
        assertLt(toSlash, 100_000e18 / 1e8, "junior cannot deliver a sat");

        _mintStable(defaultLiquidator, repay);
        uint256 seniorBefore = Tranche(senior).totalAssets();

        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 slashed) = market.liquidate(defaultLiquidator, repay);

        assertEq(repaid, repay);
        assertEq(slashed, toSlash, "senior delivered the remainder");
        assertEq(Tranche(junior).totalAssets(), 1e8, "junior lost nothing");
        assertEq(btc.balanceOf(defaultLiquidator), 0);
        assertEq(Tranche(senior).totalAssets(), seniorBefore - toSlash);
        assertEq(collateral.balanceOf(defaultLiquidator), toSlash);
    }

    /// @dev An empty junior does not need a price, so retiring its feed cannot stall the waterfall.
    function test_slash_emptyTrancheDoesNotConsultTheOracle() public {
        _deployCap();
        MockERC20 ghost = _newCollateral("Ghost", "GHOST", 18, 1e18);

        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(ghost);
        (address marketAddr, address[] memory tranches) =
            _createMarket("ghost", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);

        oracle.setSource(address(ghost), new IOracle.Sources[](0));

        vm.prank(marketAddr);
        assertEq(ITranche(tranches[1]).slash(1e18, makeAddr("recipient")), 0);
    }

    function _btcJuniorMarket()
        internal
        returns (FloatingMarket market, address senior, address junior, MockERC20 btc)
    {
        _deployCap();
        btc = _newCollateral("Wrapped Bitcoin", "WBTC", 8, 100_000e18);

        address[] memory assets = new address[](2);
        assets[0] = address(collateral);
        assets[1] = address(btc);

        (address marketAddr, address[] memory tranches) =
            _createMarket("btc", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        market.setFixedCreditLimit(1_000_000e18);

        senior = tranches[0];
        junior = tranches[1];
        _fundTranche(senior, address(collateral), makeAddr("senior"), 1_000e18);
        _fundTranche(junior, address(btc), makeAddr("junior"), 1e8);
    }
}
