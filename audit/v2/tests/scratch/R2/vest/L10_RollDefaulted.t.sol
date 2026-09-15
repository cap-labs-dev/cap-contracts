// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../../contracts/cap/market/FixedMarket.sol";
import { IInterestRateModel } from "../../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// R2 port of D2_RollDefaulted main test (L-10): keeper extendAdmin rolls keep minting premium
/// against debt already known unrecoverable. Also checks stablecoin.totalAssets is identical
/// with/without the rolls (pure share dilution).
contract L10_RollDefaulted is CapDeployer {
    FixedMarket market;
    address senior;
    address junior;
    address saver = makeAddr("saver");
    address uwSenior = makeAddr("uwSenior");
    address uwJunior = makeAddr("uwJunior");
    uint256 unrec0;
    uint256 cbs0;
    uint256 debt0;
    uint256 sen0;
    uint256 jun0;
    uint256 unlocked0;
    uint256 loanId;

    function setUp() public {
        _deployCap();
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        (address m, address t0, address t1) = _createFixedMarket("Fixed");
        market = FixedMarket(m);
        senior = t0;
        junior = t1;
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(senior, uwSenior, 9_000e18);
        _fundTranche(junior, uwJunior, 1_000e18);
        _depositStable(saver, 5_000e18);
    }

    function test_L10_keeperRollsMintUnbackedYieldOnDefaultedLoan() public {
        vm.prank(defaultBorrower);
        (uint256 id, uint256 principal) = market.borrow(defaultBorrower, type(uint256).max, type(uint256).max);
        emit log_named_uint("principal borrowed              ", principal);
        emit log_named_uint("debt at origination             ", market.debt(id));

        _setPrice(address(collateral), 0.1e18);
        assertLt(market.healthiness(), 1e27, "market is unhealthy");
        unrec0 = market.unrecoverableDebt();
        assertGt(unrec0, 0, "and already carries an unrecoverable shortfall");

        cbs0 = stablecoin.creditBackedSupply();
        debt0 = market.totalDebt();
        sen0 = stablecoin.balanceOf(senior);
        jun0 = stablecoin.balanceOf(junior);
        unlocked0 = stablecoin.unlockedSupply();
        emit log_named_uint("unrecoverable debt before rolls ", unrec0);

        // totalAssets with NO rolls over the same horizon, for the dilution check
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 12; ++i) {
            vm.warp(market.expiry(id) + market.grace() + i * (market.maximumTermLimit() + market.grace()));
        }
        // locals survive the snapshot revert; storage would not
        uint256 totalAssetsNoRoll = stablecoin.totalAssets();
        uint256 tsNoRoll = block.timestamp;
        vm.revertToState(snap);

        uint256 rolls = 12;
        for (uint256 i; i < rolls; ++i) {
            vm.warp(market.expiry(id) + market.grace());
            market.extendAdmin(id, type(uint256).max);
        }
        assertEq(block.timestamp, tsNoRoll, "same horizon");

        uint256 mintedTotal = stablecoin.creditBackedSupply() - cbs0;
        uint256 mintedToSenior = stablecoin.balanceOf(senior) - sen0;
        uint256 mintedToJunior = stablecoin.balanceOf(junior) - jun0;
        emit log_named_uint("rolls                           ", rolls);
        emit log_named_uint("debt after rolls                ", market.totalDebt());
        emit log_named_uint("debt growth (all phantom)       ", market.totalDebt() - debt0);
        emit log_named_uint("creditBackedSupply growth       ", mintedTotal);
        emit log_named_uint("unrecoverable debt after rolls  ", market.unrecoverableDebt());
        emit log_named_uint("unrecoverable growth            ", market.unrecoverableDebt() - unrec0);
        emit log_named_uint("cUSD minted to cUSD lenders     ", mintedTotal - mintedToSenior - mintedToJunior);
        emit log_named_uint("cUSD minted to senior tranche   ", mintedToSenior);
        emit log_named_uint("cUSD minted to junior tranche   ", mintedToJunior);
        emit log_named_uint("unlockedSupply (unchanged)      ", stablecoin.unlockedSupply());
        emit log_named_uint("stablecoin.totalAssets no rolls ", totalAssetsNoRoll);
        emit log_named_uint("stablecoin.totalAssets w/ rolls ", stablecoin.totalAssets());
        emit log_named_uint("stablecoin.totalSupply w/ rolls ", stablecoin.totalSupply());
        assertEq(stablecoin.unlockedSupply(), unlocked0, "reserve-backed supply did not move");
        // NOTE: the "byte-identical totalAssets" premise does not hold on this Stablecoin: totalAssets
        // tracks credit-backed supply, so the phantom premium inflates assets 1:1 with the phantom
        // debt and the hole only appears at write-off (badDebt). Characterise that instead.
        emit log_named_uint("totalAssets growth from rolls   ", stablecoin.totalAssets() - totalAssetsNoRoll);
        assertEq(
            stablecoin.totalAssets() - totalAssetsNoRoll,
            market.totalDebt() - debt0,
            "assets inflate 1:1 with phantom debt"
        );

        assertEq(
            market.unrecoverableDebt() - unrec0,
            market.totalDebt() - debt0,
            "every wei of rolled premium is a shortfall"
        );

        market.writeOff(id);
        emit log_named_uint("badDebt recognised at write-off ", stablecoin.badDebt());
        emit log_named_uint("of which minted by the rolls    ", stablecoin.badDebt() - unrec0);

        _claimAndRedeem();

        assertEq(
            stablecoin.badDebt(), unrec0, "write-off should not exceed the shortfall that existed before the rolls"
        );
    }

    function _claimAndRedeem() internal {
        vm.prank(uwSenior);
        uint256 claimed = Tranche(senior).claim(uwSenior);
        vm.warp(block.timestamp + 30 days); // exponential vest, 12h constant: ~all released
        vm.prank(uwSenior);
        claimed += Tranche(senior).claim(uwSenior);
        emit log_named_uint("senior underwriter claimed cUSD ", claimed);
        uint256 usdcBefore = cusdUnderlying.balanceOf(uwSenior);
        uint256 maxRedeem = stablecoin.maxRedeem(uwSenior);
        uint256 toRedeem = claimed < maxRedeem ? claimed : maxRedeem;
        vm.prank(uwSenior);
        stablecoin.redeem(toRedeem, uwSenior, uwSenior);
        emit log_named_uint("USDC redeemed from the reserve  ", cusdUnderlying.balanceOf(uwSenior) - usdcBefore);
        assertGt(cusdUnderlying.balanceOf(uwSenior) - usdcBefore, 0, "phantom yield was cashed out of the reserve");
    }

    /// Floating analogue (D2 test 3): anyone can poke chargePremium on defaulted debt.
    function test_L10_floatingAccruesOnUnrecoverableDebtWithoutAnyRole() public {
        MarketBundle memory b = _createReadyMarket("Floating");
        _fundTranche(b.tranche0Addr, makeAddr("uw"), 10_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max);
        _setPrice(address(collateral), 0.1e18);
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
