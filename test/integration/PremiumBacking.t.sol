// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @title PremiumBackingTest
/// @notice Debt is only ever settled by burning credit-backed stablecoin, so every unit of premium
/// added to a borrower's debt must be matched by a unit minted. These tests pin that invariant
/// across the cases where the two used to diverge.
contract PremiumBackingTest is CapDeployer {
    uint256 internal constant PRINCIPAL = 1_000e18;

    function _seniorOnlyMarket() internal returns (FloatingMarket market, address t0, address t1) {
        address marketAddr;
        (marketAddr, t0, t1) = _createMarket("M");
        market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        market.setFixedCreditLimit(100_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);
    }

    /// An empty tranche used to swallow its weighted slice of the premium: debt went up, no cUSD
    /// was minted, and the loan could never be closed.
    function test_emptyTranche_premiumStillFullyMinted() public {
        _deployCap();
        (FloatingMarket market,, address t1) = _seniorOnlyMarket();
        assertEq(Tranche(t1).activeSupply(), 0, "junior must be empty for this case to bite");

        uint256 debtBefore = market.totalDebt();
        uint256 supplyBefore = stablecoin.creditBackedSupply();

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, PRINCIPAL);

        vm.warp(block.timestamp + 365 days);
        market.chargePremium();

        assertEq(
            market.totalDebt() - debtBefore,
            stablecoin.creditBackedSupply() - supplyBefore,
            "debt growth must equal cUSD minted"
        );
    }

    /// The direct consequence: a borrower holding the full debt must be able to clear it.
    function test_emptyTranche_fullRepaySucceeds() public {
        _deployCap();
        (FloatingMarket market,,) = _seniorOnlyMarket();

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, PRINCIPAL);
        vm.warp(block.timestamp + 365 days);
        market.chargePremium();

        uint256 debt = market.totalDebt();
        assertGt(debt, PRINCIPAL, "premium should have accrued");

        // top the borrower up to the full debt with a genuine deposit
        uint256 short = debt - stablecoin.balanceOf(defaultBorrower);
        cusdUnderlying.mint(defaultBorrower, short);
        vm.startPrank(defaultBorrower);
        cusdUnderlying.approve(address(stablecoin), short);
        stablecoin.deposit(short, defaultBorrower);

        uint256 repaid = market.repay(debt);
        vm.stopPrank();

        assertEq(repaid, debt, "whole debt repaid");
        assertEq(market.totalDebt(), 0, "no residual debt");
    }

    /// An empty junior's weight is leftover, so the senior (index 0) absorbs it.
    function test_emptyTranche_weightRedistributedToActiveTranche() public {
        _deployCap();
        (FloatingMarket market, address t0,) = _seniorOnlyMarket();

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, PRINCIPAL);
        vm.warp(block.timestamp + 365 days);

        (, uint256 underwriterPremium) = market.premium();
        assertGt(underwriterPremium, 0, "expected an underwriter premium");

        uint256 seniorBefore = stablecoin.balanceOf(t0);
        market.chargePremium();

        // senior weight is 95%, but with the junior empty the leftover 5% goes to the senior
        assertEq(stablecoin.balanceOf(t0) - seniorBefore, underwriterPremium, "senior absorbs leftover");
    }

    /// An empty senior cannot take leftover, so it is minted to the staked stablecoin instead.
    function test_emptySenior_leftoverGoesToStakedStablecoin() public {
        _deployCap();
        (address marketAddr, address t0, address t1) = _createMarket("M");
        FloatingMarket market = FloatingMarket(marketAddr);
        _setMarketSlopes(marketAddr);
        market.setFixedCreditLimit(100_000e18);
        _fundTranche(t1, makeAddr("junior"), 10_000e18);
        assertEq(Tranche(t0).activeSupply(), 0, "senior must be empty");

        uint256 debtBefore = market.totalDebt();
        uint256 supplyBefore = stablecoin.creditBackedSupply();

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, PRINCIPAL);
        vm.warp(block.timestamp + 365 days);

        (uint256 liquidityPremium, uint256 underwriterPremium) = market.premium();
        uint256 juniorShare = underwriterPremium * 0.05e27 / 1e27;
        uint256 leftover = underwriterPremium - juniorShare;

        address staked = market.stakedStablecoin();
        uint256 stakedBefore = stablecoin.balanceOf(staked);
        uint256 juniorBefore = stablecoin.balanceOf(t1);

        market.chargePremium();

        assertApproxEqAbs(stablecoin.balanceOf(t1) - juniorBefore, juniorShare, 1, "junior takes only its weight");
        assertApproxEqAbs(
            stablecoin.balanceOf(staked) - stakedBefore, liquidityPremium + leftover, 1, "leftover to staked"
        );
        assertEq(market.totalDebt() - debtBefore, stablecoin.creditBackedSupply() - supplyBefore, "full premium minted");
    }

    /// The floating market splits debt growth between the liquidity and underwriter recipients.
    /// The split is only exact if it uses the underwriter index for the liquidity term, so this
    /// runs with the two rates far apart, where the indices diverge fastest.
    function test_floatingMarket_splitMatchesDebtGrowth_divergentRates() public {
        _deployCap();
        irm.setLiquiditySlopes(IInterestRateModel.Slopes({ base: 0.5e27, slope0: 0, slope1: 0, kink: 0.8e27 }));

        (address marketAddr, address t0, address t1) = _createMarket("M");
        FloatingMarket market = FloatingMarket(marketAddr);
        market.setUnderwriterRate(0.01e27); // 1% underwriter against 50% liquidity
        market.setFixedCreditLimit(100_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);
        _fundTranche(t1, makeAddr("junior"), 10_000e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, PRINCIPAL);
        vm.warp(block.timestamp + 365 days);
        market.chargePremium();

        // several intervals, so any per-charge error would compound visibly
        for (uint256 round; round < 3; ++round) {
            uint256 debtBefore = market.totalDebt();
            uint256 supplyBefore = stablecoin.creditBackedSupply();

            vm.warp(block.timestamp + 365 days);
            uint256 trueGrowth = market.totalDebt() - debtBefore;
            market.chargePremium();
            uint256 minted = stablecoin.creditBackedSupply() - supplyBefore;

            assertApproxEqAbs(minted, trueGrowth, 2, "premium minted must track debt growth");
        }

        assertApproxEqAbs(stablecoin.creditBackedSupply(), market.totalDebt(), 10, "supply and debt must stay in step");
    }

    /// Same invariant on the fixed market, where the premium is charged upfront in one shot.
    function test_fixedMarket_premiumFullyMintedWithEmptyTranche() public {
        _deployCap();
        (address marketAddr, address t0, address t1) = _createFixedMarket("F");
        FixedMarket market = FixedMarket(marketAddr);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(100_000e18);
        _fundTranche(t0, makeAddr("senior"), 10_000e18);
        assertEq(Tranche(t1).activeSupply(), 0, "junior must be empty");

        uint256 supplyBefore = stablecoin.creditBackedSupply();

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, PRINCIPAL, 30 days);

        assertEq(market.debt(id), stablecoin.creditBackedSupply() - supplyBefore, "debt must equal cUSD minted");
    }
}
