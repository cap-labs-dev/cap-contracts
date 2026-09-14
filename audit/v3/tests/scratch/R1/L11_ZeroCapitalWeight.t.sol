// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// Round-3 port of round-1 L-11 (C4/D2). HEAD `_earnsPremium` (BaseMarket.sol:482-485) requires
/// `stakedSupply() > 0` AND `totalCapital() > 0`, so a zero-capital tranche no longer takes its
/// weight. Dust capital (> 0 wei) still takes the full weight: that is I39 (WS-D), logged here.
contract R1_L11_ZeroCapitalWeight is CapDeployer {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address uwSenior = makeAddr("uwSenior");
    address uwJunior = makeAddr("uwJunior");

    function setUp() public {
        _deployCap();
    }

    function test_L11_wipedTrancheKeepsEarningItsWeight_floating() public {
        MarketBundle memory b = _createReadyMarket("M");
        _fundTranche(address(b.tranche0), alice, 1000e18);
        _fundTranche(address(b.tranche1), bob, 10e18);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);

        _setPrice(address(collateral), 0.4e18);
        _mintStable(defaultLiquidator, 20e18);
        vm.prank(defaultLiquidator);
        b.market.liquidate(defaultLiquidator, 20e18); // 20.4 USD of slash, junior holds 4 USD: wiped
        emit log_named_uint("junior totalAssets", b.tranche1.totalAssets());
        emit log_named_uint("junior stakedSupply", b.tranche1.stakedSupply());
        emit log_named_string("junior killed", b.tranche1.killed() ? "yes" : "no");
        assertGt(b.tranche1.stakedSupply(), 0, "still has staked shares");

        uint256 before = stablecoin.balanceOf(address(b.tranche1));
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        uint256 got = stablecoin.balanceOf(address(b.tranche1)) - before;
        emit log_named_uint("premium minted to wiped junior over 30 days (cUSD)", got);
        emit log_named_uint("premium minted to senior over 30 days (cUSD)", stablecoin.balanceOf(address(b.tranche0)));
        if (b.tranche1.totalCapital() == 0) {
            assertEq(got, 0, "a tranche with zero capital bears no risk and should earn no premium");
        } else {
            emit log_named_uint("junior kept dust capital (I39 case, WS-D)", b.tranche1.totalCapital());
        }
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
        emit log_named_uint("senior capital left after liquidation", Tranche(senior).totalCapital());
        emit log_named_uint("junior capital left after liquidation", Tranche(junior).totalCapital());

        uint256 sen0 = stablecoin.balanceOf(senior);
        uint256 jun0 = stablecoin.balanceOf(junior);
        for (uint256 i; i < 12; ++i) {
            vm.warp(market.expiry(id) + market.grace());
            market.extendAdmin(id, type(uint256).max);
        }
        uint256 toSenior = stablecoin.balanceOf(senior) - sen0;
        uint256 toJunior = stablecoin.balanceOf(junior) - jun0;
        emit log_named_uint("premium minted to senior", toSenior);
        emit log_named_uint("premium minted to junior", toJunior);
        // L-11 property: premium only where capital remains
        assertTrue(toSenior == 0 || Tranche(senior).totalCapital() > 0, "senior earned with zero capital");
        assertTrue(toJunior == 0 || Tranche(junior).totalCapital() > 0, "junior earned with zero capital");
    }
}
