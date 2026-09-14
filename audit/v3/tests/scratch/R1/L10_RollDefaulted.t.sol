// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 L-10 (D2). KEEPER `extendAdmin` (FixedMarket.sol:113-124) and the
/// public floating `chargePremium` keep minting premium against debt already known
/// unrecoverable; `_chargePremiumForTerm` charges on the full `debt[id]` (:359-367).
/// API: `redeem`/`maxRedeem` -> `instantRedeem`/`maxInstantRedeem`.
contract R1_L10_RollDefaulted is CapDeployer {
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

        _setPrice(address(collateral), 0.1e18);
        assertLt(market.healthiness(), 1e27, "market is unhealthy");
        uint256 unrec0 = market.unrecoverableDebt();
        assertGt(unrec0, 0, "and already carries an unrecoverable shortfall");
        uint256 cbs0 = stablecoin.creditBackedSupply();
        uint256 debt0 = market.totalDebt();
        uint256 assets0 = stablecoin.totalAssets();
        emit log_named_uint("unrecoverable debt before rolls ", unrec0);

        uint256 rolls = 12;
        for (uint256 i; i < rolls; ++i) {
            vm.warp(market.expiry(id) + market.grace());
            market.extendAdmin(id, type(uint256).max);
        }
        emit log_named_uint("debt growth (all phantom)       ", market.totalDebt() - debt0);
        emit log_named_uint("creditBackedSupply growth       ", stablecoin.creditBackedSupply() - cbs0);
        emit log_named_uint("unrecoverable growth            ", market.unrecoverableDebt() - unrec0);
        emit log_named_uint("stablecoin.totalAssets growth   ", stablecoin.totalAssets() - assets0);
        assertEq(
            market.unrecoverableDebt() - unrec0,
            market.totalDebt() - debt0,
            "every wei of rolled premium is a shortfall"
        );

        market.writeOff(id);
        emit log_named_uint("badDebt recognised at write-off ", stablecoin.badDebt());
        emit log_named_uint("of which minted by the rolls    ", stablecoin.badDebt() - unrec0);

        vm.warp(block.timestamp + 30 days);
        vm.prank(uwSenior);
        uint256 claimed = Tranche(senior).claim(uwSenior);
        uint256 maxR = stablecoin.maxInstantRedeem(uwSenior);
        uint256 toRedeem = claimed < maxR ? claimed : maxR;
        uint256 usdcBefore = cusdUnderlying.balanceOf(uwSenior);
        vm.prank(uwSenior);
        stablecoin.instantRedeem(toRedeem, uwSenior, uwSenior);
        emit log_named_uint("senior underwriter claimed cUSD ", claimed);
        emit log_named_uint("USDC redeemed from the reserve  ", cusdUnderlying.balanceOf(uwSenior) - usdcBefore);

        assertEq(
            stablecoin.badDebt(), unrec0, "write-off should not exceed the shortfall that existed before the rolls"
        );
    }

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
