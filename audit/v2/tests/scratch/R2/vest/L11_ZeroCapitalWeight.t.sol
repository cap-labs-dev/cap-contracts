// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";

/// R2 port (L-11) of C4.test_wipedTrancheKeepsEarningItsWeight and
/// D2.test_H3_slashedToZeroTranchesStillReceivePremiumOnRoll: a tranche with zero capital keeps
/// its premium weight because _chargePremium gates on stakedSupply (opted-in shares), not capital.
contract L11_ZeroCapitalWeight is CapDeployer {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address uwSenior = makeAddr("uwSenior");
    address uwJunior = makeAddr("uwJunior");

    function setUp() public {
        _deployCap();
    }

    function test_L11_wipedTrancheKeepsEarningItsWeight_floating() public {
        MarketBundle memory b = _createReadyMarket("M");
        FloatingMarket market = b.market;
        Tranche senior = b.tranche0;
        Tranche junior = b.tranche1;
        _fundTranche(address(senior), alice, 1000e18);
        _fundTranche(address(junior), bob, 10e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);

        _setPrice(address(collateral), 0.4e18);
        _mintStable(defaultLiquidator, 20e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 20e18); // 20.4 USD of slash, junior holds 4 USD: wiped
        assertEq(junior.totalAssets(), 0, "junior wiped");
        assertGt(junior.stakedSupply(), 0, "but still has staked shares");
        emit log_named_string("junior killed", junior.killed() ? "yes" : "no");
        emit log_named_uint("junior totalCapital", junior.totalCapital());
        emit log_named_uint("junior stakedSupply", junior.stakedSupply());

        uint256 before = stablecoin.balanceOf(address(junior));
        vm.warp(block.timestamp + 30 days);
        market.chargePremium();
        uint256 got = stablecoin.balanceOf(address(junior)) - before;
        emit log_named_uint("premium minted to wiped junior over 30 days (cUSD)", got);
        emit log_named_uint("premium minted to senior over 30 days (cUSD)", stablecoin.balanceOf(address(senior)));
        assertEq(got, 0, "a tranche with zero capital bears no risk and should earn no premium");
    }

    function test_L11_slashedToZeroTranchesStillReceivePremiumOnRoll_fixed() public {
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        (address m, address senior, address junior) = _createFixedMarket("Fixed");
        FixedMarket market = FixedMarket(m);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(senior, uwSenior, 9_000e18);
        _fundTranche(junior, uwJunior, 1_000e18);
        _depositStable(makeAddr("saver"), 5_000e18);

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, type(uint256).max, type(uint256).max);
        _setPrice(address(collateral), 0.1e18);

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
        emit log_named_uint("senior stakedSupply (0 capital)", Tranche(senior).stakedSupply());
        emit log_named_uint("premium minted to senior (0 capital)", stablecoin.balanceOf(senior) - sen0);
        emit log_named_uint("premium minted to junior (0 capital)", stablecoin.balanceOf(junior) - jun0);
        emit log_named_string("junior killed", Tranche(junior).killed() ? "yes" : "no");
        assertEq(stablecoin.balanceOf(senior) - sen0, 0, "a tranche with no capital should earn no premium");
    }
}
