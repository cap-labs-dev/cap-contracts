// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";

/// @notice Verification of MED-PHANTOM-YIELD (D2 / H3). Same setup as the PoC, but with a
/// counterfactual branch so the loss can be attributed: who is worse off, by how much, and
/// whether the aggregate backing (totalAssets) actually changes.
contract Verify_PhantomYield is CapDeployer {
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

    function _crash() internal returns (uint256 id) {
        vm.prank(defaultBorrower);
        (id,) = market.borrow(defaultBorrower, type(uint256).max, type(uint256).max);
        oracle.setPrice(address(collateral), 0.1e18);
    }

    function _report(string memory tag) internal {
        emit log_string(tag);
        emit log_named_uint("  totalSupply            ", stablecoin.totalSupply());
        emit log_named_uint("  badDebt                ", stablecoin.badDebt());
        emit log_named_uint("  totalAssets            ", stablecoin.totalAssets());
        emit log_named_uint("  reserve USDC           ", cusdUnderlying.balanceOf(address(stablecoin)));
        emit log_named_uint("  saver previewRedeem 5k ", stablecoin.previewRedeem(5_000e18));
        emit log_named_uint("  flat backing (1e18)    ", stablecoin.totalAssets() * 1e18 / stablecoin.totalSupply());
    }

    /// @dev Angle (a): counterfactual. Branch 1 writes off promptly; branch 2 rolls 12x then writes
    /// off. Compare totalAssets (aggregate backing) and the saver's redeemable value.
    function test_counterfactual_promptWriteOff_vs_twelveRolls() public {
        uint256 id = _crash();
        uint256 snap = vm.snapshotState();

        // ---- branch 1: guardian writes off immediately
        market.writeOff(id);
        _report("BRANCH 1: prompt write-off, no rolls");
        uint256 assets1 = stablecoin.totalAssets();
        uint256 saver1 = stablecoin.previewRedeem(5_000e18);
        uint256 supply1 = stablecoin.totalSupply();

        vm.revertToState(snap);

        // ---- branch 2: 12 keeper rolls, then write-off
        for (uint256 i; i < 12; ++i) {
            vm.warp(market.expiry(id) + market.grace());
            market.extendAdmin(id, type(uint256).max);
        }
        market.writeOff(id);
        _report("BRANCH 2: 12 rolls, then write-off");
        uint256 assets2 = stablecoin.totalAssets();
        uint256 saver2 = stablecoin.previewRedeem(5_000e18);
        uint256 supply2 = stablecoin.totalSupply();

        emit log_named_uint("supply growth (phantom cUSD)  ", supply2 - supply1);
        emit log_named_int("totalAssets delta (2 - 1)     ", int256(assets2) - int256(assets1));
        emit log_named_int("saver redeemable delta (2 - 1)", int256(saver2) - int256(saver1));

        // the aggregate backing is identical: phantom yield is a dilution (transfer), not a loss
        assertEq(assets2, assets1, "totalAssets unchanged by phantom yield");
        // the saver (plain cUSD holder) is worse off
        assertLt(saver2, saver1, "saver diluted");

        // ---- now the senior underwriter claims & redeems; does that hurt or help remaining holders?
        uint256 saverBefore = stablecoin.previewRedeem(5_000e18);
        uint256 flatBefore = stablecoin.totalAssets() * 1e18 / stablecoin.totalSupply();
        vm.prank(uwSenior);
        uint256 claimed = Tranche(senior).claim(uwSenior);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(uwSenior);
        claimed += Tranche(senior).claim(uwSenior);
        uint256 usdc0 = cusdUnderlying.balanceOf(uwSenior);
        uint256 bad0 = stablecoin.badDebt();
        vm.prank(uwSenior);
        stablecoin.redeem(claimed, uwSenior, uwSenior);
        uint256 got = cusdUnderlying.balanceOf(uwSenior) - usdc0;
        emit log_named_uint("uw claimed cUSD               ", claimed);
        emit log_named_uint("uw USDC received              ", got);
        emit log_named_uint("uw cUSD value at flat ratio   ", claimed * flatBefore / 1e18);
        emit log_named_uint("badDebt retired by uw exit    ", bad0 - stablecoin.badDebt());
        _report("AFTER underwriter redeem");
        uint256 saverAfter = stablecoin.previewRedeem(5_000e18);
        emit log_named_int("saver redeemable delta (post-redeem - pre)", int256(saverAfter) - int256(saverBefore));
        // the underwriter's exit is priced BELOW the flat ratio, so remaining holders are repaired, not front-run
        assertLt(got, claimed * flatBefore / 1e18, "exit below flat ratio");
        assertGe(saverAfter, saverBefore, "saver not hurt by the underwriter's exit");
    }

    /// @dev Is prompt write-off actually a brake? After write-off the debt sits exactly at the
    /// recoverable level, so the very next roll re-creates an unrecoverable slice. Only liquidation
    /// of the residual ends the accrual.
    function test_writeOffAloneDoesNotStopReaccrual_liquidationDoes() public {
        uint256 id = _crash();
        market.writeOff(id);
        assertEq(market.unrecoverableDebt(), 0);
        uint256 debt0 = market.debt(id);
        for (uint256 i; i < 12; ++i) {
            vm.warp(market.expiry(id) + market.grace());
            market.extendAdmin(id, type(uint256).max);
        }
        emit log_named_uint("residual debt after write-off ", debt0);
        emit log_named_uint("debt after 12 more rolls      ", market.debt(id));
        emit log_named_uint("unrecoverable re-accrued      ", market.unrecoverableDebt());
        assertGt(market.unrecoverableDebt(), 0, "rolls re-create an unrecoverable slice after write-off");

        // liquidate the residual (write off the re-accrued slice first so the liquidation cap covers it)
        market.writeOff(id);
        _depositStable(defaultLiquidator, market.debt(id) + 1e18);
        vm.prank(defaultLiquidator);
        market.liquidate(id, defaultLiquidator, type(uint256).max);
        emit log_named_uint("debt after liquidation        ", market.debt(id));
        uint256 cbs = stablecoin.creditBackedSupply();
        vm.warp(market.expiry(id) + market.grace());
        market.extendAdmin(id, type(uint256).max);
        emit log_named_uint("minted by a roll on 0 debt    ", stablecoin.creditBackedSupply() - cbs);
        assertEq(stablecoin.creditBackedSupply(), cbs, "nothing to mint once the debt is cleared");
    }

    /// @dev Angle (b): can a borrower make the market unrecoverable on their own (to trip a
    /// hypothetical `unrecoverableDebt()==0` guard or a `min(debt, recoverable)` charge)? Under the
    /// deployer's parameters (lt 0.8, bonus 0.02) a healthy market can never be unrecoverable.
    function test_griefingLever_needsLtTimesBonusAboveOne() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max, type(uint256).max);
        emit log_named_uint("lt * (1+bonus) (ray)          ", market.lt() * (1e27 + irm.liquidationBonus()) / 1e27);
        emit log_named_uint("unrecoverable at max draw     ", market.unrecoverableDebt());
        assertEq(market.unrecoverableDebt(), 0, "max draw cannot be unrecoverable while healthy at these params");
    }

    /// @dev Floating: the shortfall grows with time as a pure view; the permissionless poke only
    /// materialises what the index already says. Nobody needs to call anything.
    function test_floatingShortfallGrowsWithoutAnyCall() public {
        MarketBundle memory b = _createReadyMarket("Floating");
        _fundTranche(b.tranche0Addr, makeAddr("uw"), 10_000e18);
        b.market.setFixedCreditLimit(type(uint256).max);
        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, type(uint256).max);
        oracle.setPrice(address(collateral), 0.1e18);
        uint256 unrec0 = b.market.unrecoverableDebt();
        uint256 cbs0 = stablecoin.creditBackedSupply();
        vm.warp(block.timestamp + 360 days);
        emit log_named_uint("unrecoverable t0              ", unrec0);
        emit log_named_uint("unrecoverable t0+360d, no call", b.market.unrecoverableDebt());
        emit log_named_uint("cUSD minted meanwhile         ", stablecoin.creditBackedSupply() - cbs0);
        assertGt(b.market.unrecoverableDebt(), unrec0, "grows with time alone");
        assertEq(stablecoin.creditBackedSupply(), cbs0, "nothing minted until someone pokes");
        // and the write-off itself mints the accrued premium first (writeOff -> _chargePremium)
        b.market.writeOff();
        emit log_named_uint(
            "minted by the write-off call  ", stablecoin.creditBackedSupply() + stablecoin.badDebt() - cbs0
        );
    }
}
