// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice WS-D / H3. A defaulted, deeply underwater fixed loan is rolled by the keeper every
/// term. Each roll charges a full premium on the whole (already unrecoverable) debt and mints it
/// as fresh credit-backed cUSD to stcUSD and to the tranches. Nothing backs that cUSD: the
/// collateral is already exhausted and the borrower will never repay. The loss lands on cUSD
/// holders at write-off, grown by every roll in between. The floating analogue needs no keeper:
/// permissionless chargePremium does the same thing on every poke.
contract D2_RollDefaulted is CapDeployer {
    FixedMarket market;
    address senior;
    address junior;
    address saver = makeAddr("saver");
    address uwSenior = makeAddr("uwSenior");
    address uwJunior = makeAddr("uwJunior");

    function setUp() public {
        _deployCap();
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        (address m, address t0, address t1) = _createFixedMarket("Fixed");
        market = FixedMarket(m);
        senior = t0;
        junior = t1;
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate); // 20%
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(senior, uwSenior, 9_000e18);
        _fundTranche(junior, uwJunior, 1_000e18);
        // idle reserve so utilization is realistic (~50%) and so premium cUSD is redeemable
        _depositStable(saver, 5_000e18);
    }

    function test_H3_keeperRollsMintUnbackedYieldOnDefaultedLoan() public {
        vm.prank(defaultBorrower);
        (uint256 id, uint256 principal) = market.borrow(defaultBorrower, type(uint256).max, type(uint256).max);
        emit log_named_uint("principal borrowed              ", principal);
        emit log_named_uint("debt at origination             ", market.debt(id));

        // collateral drops 90%: 10_000 tokens now back $1_000 of ~$5_000 of debt
        oracle.setPrice(address(collateral), 0.1e18);
        assertLt(market.healthiness(), 1e27, "market is unhealthy");
        uint256 unrec0 = market.unrecoverableDebt();
        assertGt(unrec0, 0, "and already carries an unrecoverable shortfall");

        uint256 cbs0 = stablecoin.creditBackedSupply();
        uint256 debt0 = market.totalDebt();
        uint256 stc0 = stablecoin.balanceOf(capConfig.stablecoinYield);
        uint256 sen0 = stablecoin.balanceOf(senior);
        uint256 jun0 = stablecoin.balanceOf(junior);
        uint256 unlocked0 = stablecoin.unlockedSupply();
        emit log_named_uint("unrecoverable debt before rolls ", unrec0);

        // keeper (this contract) rolls the loan at expiry + grace, twelve times (~one year)
        uint256 rolls = 12;
        for (uint256 i; i < rolls; ++i) {
            vm.warp(market.expiry(id) + market.grace());
            market.extendAdmin(id, type(uint256).max);
        }

        uint256 mintedToLenders = stablecoin.balanceOf(capConfig.stablecoinYield) - stc0;
        uint256 mintedToSenior = stablecoin.balanceOf(senior) - sen0;
        uint256 mintedToJunior = stablecoin.balanceOf(junior) - jun0;
        emit log_named_uint("rolls                           ", rolls);
        emit log_named_uint("debt after rolls                ", market.totalDebt());
        emit log_named_uint("debt growth (all phantom)       ", market.totalDebt() - debt0);
        emit log_named_uint("creditBackedSupply growth       ", stablecoin.creditBackedSupply() - cbs0);
        emit log_named_uint("unrecoverable debt after rolls  ", market.unrecoverableDebt());
        emit log_named_uint("unrecoverable growth            ", market.unrecoverableDebt() - unrec0);
        emit log_named_uint("cUSD minted to stcUSD           ", mintedToLenders);
        emit log_named_uint("cUSD minted to senior tranche   ", mintedToSenior);
        emit log_named_uint("cUSD minted to junior tranche   ", mintedToJunior);
        emit log_named_uint("unlockedSupply (unchanged)      ", stablecoin.unlockedSupply());
        assertEq(stablecoin.unlockedSupply(), unlocked0, "reserve-backed supply did not move");

        // the entire debt growth is unrecoverable: the collateral was already exhausted
        assertEq(
            market.unrecoverableDebt() - unrec0,
            market.totalDebt() - debt0,
            "every wei of rolled premium is a shortfall"
        );

        // guardian finally writes off: the bad debt socialised on cUSD holders is the original
        // shortfall plus everything the rolls minted
        market.writeOff(id);
        emit log_named_uint("badDebt recognised at write-off ", stablecoin.badDebt());
        emit log_named_uint("of which minted by the rolls    ", stablecoin.badDebt() - unrec0);

        // the yield the rolls paid out is real, spendable cUSD: the senior underwriter claims it
        // and redeems it against the reserve at par, ahead of the depositors who now carry badDebt
        vm.prank(uwSenior);
        uint256 claimed = Tranche(senior).claim(uwSenior);
        // premium vests over 6h; wait it out and claim the rest
        vm.warp(block.timestamp + 6 hours);
        vm.prank(uwSenior);
        claimed += Tranche(senior).claim(uwSenior);
        emit log_named_uint("senior underwriter claimed cUSD ", claimed);
        uint256 usdcBefore = cusdUnderlying.balanceOf(uwSenior);
        vm.prank(uwSenior);
        stablecoin.redeem(claimed, uwSenior, uwSenior);
        emit log_named_uint("USDC redeemed from the reserve  ", cusdUnderlying.balanceOf(uwSenior) - usdcBefore);
        assertGt(cusdUnderlying.balanceOf(uwSenior) - usdcBefore, 0, "phantom yield was cashed out of the reserve");

        // the property that should hold: no premium is minted against debt no one can recover
        assertEq(
            stablecoin.badDebt(), unrec0, "write-off should not exceed the shortfall that existed before the rolls"
        );
    }

    /// @dev Same thing after the liquidator has already taken everything: the tranches hold zero
    /// collateral (and the junior is `killed`) yet still receive premium on every roll, because
    /// _chargePremium routes by stakedSupply (shares), not by capital.
    function test_H3_slashedToZeroTranchesStillReceivePremiumOnRoll() public {
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, type(uint256).max, type(uint256).max);
        oracle.setPrice(address(collateral), 0.1e18);

        // liquidator clears everything the collateral can clear
        uint256 maxLiq = market.maxLiquidatable();
        _depositStable(defaultLiquidator, maxLiq + 1e18);
        vm.prank(defaultLiquidator);
        market.liquidate(id, defaultLiquidator, type(uint256).max);
        emit log_named_uint("capital left after liquidation ", market.totalCapital());
        emit log_named_uint("debt left after liquidation    ", market.totalDebt());
        assertLe(market.totalCapital(), 1e18, "collateral is gone");
        assertEq(market.recoverableDebt(), market.totalCapital() * 1e27 / (1e27 + irm.liquidationBonus()));

        uint256 sen0 = stablecoin.balanceOf(senior);
        uint256 jun0 = stablecoin.balanceOf(junior);
        for (uint256 i; i < 12; ++i) {
            vm.warp(market.expiry(id) + market.grace());
            market.extendAdmin(id, type(uint256).max);
        }
        emit log_named_uint("premium minted to senior (0 capital)", stablecoin.balanceOf(senior) - sen0);
        emit log_named_uint("premium minted to junior (0 capital)", stablecoin.balanceOf(junior) - jun0);
        emit log_named_string("junior killed", Tranche(junior).killed() ? "yes" : "no");
        assertEq(stablecoin.balanceOf(senior) - sen0, 0, "a tranche with no capital should earn no premium");
    }

    /// @dev Floating analogue: no keeper needed. Anyone can poke chargePremium and the defaulted
    /// debt keeps minting yield until the guardian writes it off.
    function test_H3_floatingAccruesOnUnrecoverableDebtWithoutAnyRole() public {
        MarketBundle memory b = _createReadyMarket("Floating");
        _fundTranche(b.tranche0Addr, makeAddr("uw"), 10_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max);
        oracle.setPrice(address(collateral), 0.1e18);
        uint256 unrec0 = b.market.unrecoverableDebt();
        uint256 cbs0 = stablecoin.creditBackedSupply();
        for (uint256 i; i < 12; ++i) {
            vm.warp(block.timestamp + 30 days);
            vm.prank(makeAddr("anyone"));
            b.market.chargePremium();
        }
        emit log_named_uint("unrecoverable before ", unrec0);
        emit log_named_uint("unrecoverable after  ", b.market.unrecoverableDebt());
        emit log_named_uint("cUSD minted meanwhile", stablecoin.creditBackedSupply() - cbs0);
        assertEq(b.market.unrecoverableDebt(), unrec0, "shortfall should not compound while nobody can recover it");
    }
}
